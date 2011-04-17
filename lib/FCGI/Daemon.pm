#!/usr/bin/perl
package FCGI::Daemon;
BEGIN {
    use English '-no_match_vars';
    eval q{use FCGI 0.71; use FCGI::ProcManager 0.18;};
    print {*STDERR} $EVAL_ERROR."## Perhaps you need to have qw(libfcgi-perl libfcgi-procmanager-perl) installed?\n" and exit 1 if $EVAL_ERROR; 
}
use 5.008;
use strict;
#use warnings;
#use diagnostics -verbose;
use Getopt::Std;
use autouse 'Pod::Usage'=>qw(pod2usage);
sub help { pod2usage(-verbose=>$ARG[0],-noperldoc=>1) and exit; }

=head1 NAME

FCGI::Daemon - an easy to use FastCGI daemon which can be used with nginx web server.

=head1 VERSION

Version 0.20110419_01

=cut

our $VERSION = '0.20110419_01';
my %o;


__PACKAGE__->run() unless caller();     # modulino i.e. executable rather than module


sub run {
    getopts('hde:q:p:s:g:u:m:c:l:w:',\%o) or help(0);
    help(2) if $o{'h'};

    $o{sockfile}=$o{'s'}||'/var/run/fcgid.sock';
    $o{pidfile}=$o{'p'}||'/var/run/fcgid.pid' if $o{'d'};
    $o{prefork}=defined $o{'w'} ? $o{'w'} : 1;
    $o{queue}=defined $o{'q'} ? $o{'q'} : 96;
    $o{rlimit_vmem}=($o{'m'}||512)*1024*1024;
    $o{rlimit_cpu}=$o{'c'}||32;
    $o{max_evals}=defined $o{'e'} ? $o{'e'} : 10240;   #max evals before exit - paranoid to free memory if leaks
    $o{leak_threshold}=$o{'l'}||1.3;

    if($REAL_USER_ID==$EFFECTIVE_USER_ID and $EFFECTIVE_USER_ID==0){        # if run as root
        $o{gid}=$o{g}||'www-data'; $o{gid_num}=scalar getgrnam($o{gid});
        $o{uid}=$o{u}||'www-data'; $o{uid_num}=scalar getpwnam($o{uid});
    }

    sub dieif { 
        if($ARG[0]){
            my $err=$ARG[1];
            unlink @o{'pidfile','sockfile'};
            print "Error - $err:\n",$ARG[0],"\n";
            exit 1;
        }   
    }

    $SIG{INT}=$SIG{TERM}=sub{   # actually FCGI::ProcManager override our TERM handler so .sock and .pid files will be removed only by sysv script... :(
                            $o{fcgi_pm}->pm_remove_pid_file() if $o{fcgi_pm};
                            unlink @o{'sockfile','pidfile'}; 
                            $o{fcgi_pm}->pm_die() if $o{fcgi_pm};   #pm_die() does not return
                            exit 0; 
                         };

    # daemonize
    if($o{'d'}){
        chdir '/';                              # this is good practice for unmounting
        $PROGRAM_NAME='FCGI::Daemon';
        defined(my $pid=fork) or die "Can't fork: $!";
        exit if $pid;
        eval {use POSIX qw(setsid); POSIX::setsid();} or die q{Can't start a new session: }.$OS_ERROR;
        open *STDIN,'<','/dev/null';
        open *STDOUT,'>>','/dev/null';
        open *STDERR,'>>','/dev/null';
        umask 022;
    }

    main();
}

# overriding process names for sysv script in /etc/init.d
sub FCGI::ProcManager::pm_change_process_name { 
        my ($self,$name)=@_;
        my %p=( 'perl-fcgi-pm'  =>'FCGI::Daemon',
                'perl-fcgi'     =>'FCGI::Daemon-worker',
        );
        $0=$p{$name} if $p{$name} ne '';
}

sub main {
    my %req_env;
    $o{fcgi_pm}=FCGI::ProcManager->new({n_processes=>$o{prefork},
                                        die_timeout=>28,
                                        pid_fname=>$o{pidfile}
                                      });
    print "Opening socket $o{sockfile}\n";
    my $rqst=FCGI::Request(\*STDIN,\*STDOUT,\*STDERR,\%req_env,
             FCGI::OpenSocket($o{sockfile},$o{prefork}*$o{queue}),
             FCGI::FAIL_ACCEPT_ON_INTR())
        or die "Error: Unable to create FCGI::Request...";

    if(defined $o{gid_num} and defined $o{uid_num}){                # if run as root
        chown $o{uid_num},$o{gid_num},$o{sockfile}                  # chown SOCKfile
            or dieif($OS_ERROR,'Unable to chown SOCKfile');
    }

    $o{fcgi_pm}->pm_manage();   # from now on we are worker process

    # drop privileges if run as root
    if(defined $o{gid_num} and defined $o{uid_num}){
        $REAL_GROUP_ID=$EFFECTIVE_GROUP_ID=getgrnam($o{gid});
            dieif($OS_ERROR,'Unable to change group_id to '.$o{gid});
        $REAL_USER_ID=$EFFECTIVE_USER_ID=getpwnam($o{uid});
            dieif($OS_ERROR,'Unable to change user_id to '.$o{uid});
    }

    ## set rlimit(s)
    require 'syscall.ph';
    require 'sys/resource.ph';
    my $rlim=pack 'L!L!',$o{rlimit_vmem},$o{rlimit_vmem};
    dieif($OS_ERROR,"Unable to set RLIMIT_AS: ") if -1==syscall(SYS_setrlimit(),RLIMIT_AS(),$rlim);
    $rlim=pack 'L!L!',$o{rlimit_cpu},$o{rlimit_cpu};
    dieif($OS_ERROR,"Unable to set RLIMIT_CPU: ") if -1==syscall(SYS_setrlimit(),RLIMIT_CPU(),$rlim);

    REQ_LOOP:   # main loop
    while($rqst->Accept()>=0){

        $req_env{'PATH_INFO'}=$req_env{'SCRIPT_FILENAME'};
        $req_env{'SCRIPT_FILENAME'}=get_file_from_path($req_env{SCRIPT_FILENAME});
        $req_env{'PATH_INFO'}=~s/$req_env{'SCRIPT_FILENAME'}//;
        $req_env{'SCRIPT_NAME'}=$req_env{'SCRIPT_FILENAME'};
        $req_env{'SCRIPT_NAME'}=~s/$req_env{'DOCUMENT_ROOT'}//;

        # check if script (exacutable, readable, non-zero size)
        unless(-x -s -r $req_env{'SCRIPT_FILENAME'}){
            print "Content-type: text/plain\r\n\r\n"
            ."Error: No such CGI app - $req_env{SCRIPT_FILENAME} may not exist or is not executable by this process.\n";
            next;
        }

        local @ENV{keys %req_env}=values %req_env;
        chdir $1 if $req_env{'SCRIPT_FILENAME'}=~m{^(.*)\/};   # cd to the script's local directory

        # Fast Perl-CGI processing
        if($o{max_evals}>0 and $req_env{'SCRIPT_FILENAME'}=~m{\.pl\z}){   # detect if perl script
            my %allvars;
            @allvars{keys %main::}=();
            {
                local *CORE::GLOBAL::exit=sub { die 'notreallyexit'; };
                local $0=$req_env{SCRIPT_FILENAME};     #fixes FindBin (in English $0 means $PROGRAM_NAME)
                do $0;                                  # do $0; could be enough for strict scripts
            }

            $_{$req_env{SCRIPT_FILENAME}}->{SIGTERM}() if defined $_{$req_env{SCRIPT_FILENAME}}->{SIGTERM};

            foreach(keys %main::){                      # cleanup garbage after do() 
                next if exists $allvars{$_};
                next if m{::$};
                next if m{^_};
                delete $main::{$_};
            }

            if(open my $STAT,'<',"/proc/$$/status"){
                my %stat;
                while(my ($k,$v)=split /\:\s+/,<$STAT>){
                    chop $v;
                    $stat{$k}=$v;
                }
                close $STAT;
                # check if child takes too much resident memory and terminate if necessary
                if($stat{VmSize}/$stat{VmRSS}<$o{leak_threshold}){
                    print {*STDERR} 'fcgid :: terminating child - memory leak? '
                    ."VmSize:$stat{VmSize}; VmRSS:$stat{VmRSS}; Ratio:".$stat{VmSize}/$stat{VmRSS};
                    exit;
                }
            }
            exit unless --$o{max_evals};
            next REQ_LOOP;
        }
        
        # Normal CGI processing
        $o{fcgi_pm}->pm_pre_dispatch();
        local $OUTPUT_AUTOFLUSH=1;  # select below is equivalent of: my $oldfh=select($CERR); $|=1; select($oldfh);
        pipe my($PERR),my($CERR);   select((select($CERR),$OUTPUT_AUTOFLUSH=1)[0]);    #prepare child-to-parent pipe and swith off buffering
        pipe my($CIN),my($PIN);     select((select($PIN),$OUTPUT_AUTOFLUSH=1)[0]);     #prepare parent-to-child pipe and swith off buffering

        my $pid=open my($COUT),"-|";     ## fork and pipe to us
        unless(defined $pid){
            print "Content-type: text/plain\r\n\r\n"
            ."Error: CGI app returned no output - Executing $req_env{SCRIPT_FILENAME} failed !\n";
            next;
        }
        $rqst->Detach();         # needed to restore original STDIN,STDOUT,STDERR

        unless($pid){   #### Child ####
            close $PIN;     # <--perhaps not really necessary
            open *STDIN,'<&=',$CIN   or die 'unable to reopen STDIN';   
            open *STDERR,'>&=',$CERR or die 'unable to reopen STDERR';  
            exec $req_env{'SCRIPT_FILENAME'} or die "exec failed";     # running the cgi app (exec does not return so child terminates here)
        }else{          #### Parent ####
            close $CIN;             # <--perhaps not really necessary
            close $CERR;            # *must* close child's file handle to avoid deadlock
            $rqst->Attach();        #reattach FCGI's STDIN,STDOUT,STDERR

            ## send STDIN to child
            my $buffer;  
            #print {$PIN} $buffer while (read *STDIN,$buffer,$ENV{'CONTENT_LENGTH'});   ## longer version below may be safer for very long input.
            if($req_env{'REQUEST_METHOD'} eq 'POST' and $req_env{'CONTENT_LENGTH'}!=0){ 
                my $bytes=0;
                while ($bytes<$req_env{'CONTENT_LENGTH'}){
                        $bytes+=read *STDIN,$buffer,($req_env{'CONTENT_LENGTH'}-$bytes);
                        last if ($bytes==0 or !defined $bytes);
                        print {$PIN} $buffer;
            }   }
            close $PIN;

            use IO::Select;     # non-blocking read from child's redirected STDOUT and STDERR
            my $sel = IO::Select->new($COUT,$PERR);
            while(my @ready=$sel->can_read){
                for my $FH (@ready){
                    if(0==sysread $FH,$buffer,4096){
                        $sel->remove($FH);
                        close $FH;
                    }else{
                        print {$FH==$COUT ? *STDOUT:*STDERR} $buffer;
            }  }    }
            waitpid $pid,0;
            $rqst->Finish();
        }
        $o{fcgi_pm}->pm_post_dispatch();
    }
}

sub get_file_from_path {
    local $_=shift;
    my $file='';
    for(split '/',$_){
        next if $_ eq '';
        $file.='/'.$_;
        last if -f -s $file;
    }
$file;
}

1; 
__END__


=head1 SYNOPSIS

This is modulino i.e. executable FastCGI daemon.

=head1 DESCRIPTION

    FCGI::Daemon is a small (Fast)CGI server for use as CGI-wrapper for
    unmodified CGI applications. 
    
    Factored as modulino, currently it doesn't have any Perl module functionality.
    
    It was developed as replacement for cgiwrap-fcgi.pl ( see http://wiki.nginx.org/SimpleCGI )
    
=head1 FEATURES

    * setrlimit for RLIMIT_AS and RLIMIT_CPU
    * DOing .pl - run CGI scripts in Perl with persistent interpreter (like mod_perl).
    * detection of memory leaks
    * drop privileges when run as root
    * detection of script executable in path (to run CGI apps like fossil)

=cut

=head1 USAGE

    It can be manually invoked as "perl /usr/share/perl5/FCGI/Daemon.pm"
    or with included SysV init script.
    
    Please make sure that user have write permissions for sock file.

=head1 OPTIONS

Options: (default arguments given for convenience)

    -h                              # brief help message
    -w 1                            # number of preforked processes (workers)
    -q 96                           # max queue
    -m 512                          # RLIMIT_AS in MiB (see setrlimit)
    -c 32                           # RLIMIT_CPU in seconds (see setrlimit)
    -e 10240                        # max evals before process restart. 0 disables DOing perl scripts.
    -l 1.3                          # memory leak threshold
    -p /var/run/fcgid.pid           # write pId (process ID) to given file (only if daemonize)
    -s /var/run/fcgid.sock          # socket file for Fast CGI communication
    -u www-data                     # user name to become (if run as root)
    -g www-data                     # group name to become (if run as root)
    -d                              # daemonize (run in background)

=over 4

=item B<-e>

By default FCGI::Daemon DOing .pl scripts up to B<-e> times. 
This is several times faster than invoking Perl for every call of CGI script.
This option define how often parent process should restart.
Warning - some scripts may be incompatible with this so disable with "-e0" if necessary.

=item B<-l>

In DOing mode ( i.e. max_evals > 0 ) worker process terminates if 
upon CGI execution VmSize/VmRSS < leak treshold.

This is helpful for scripts that are leaking memory

=back

=head1 PREREQUISITES

    FCGI
    FCGI::ProcManager

    For Debian GNU/Linux (perhaps the best platform)
    required moduled provided by the following packages:
    
    libfcgi-perl
    libfcgi-procmanager-perl

=head1 COMPATIBILITY

Tested only in GNU/Linux systems.
Windows is NOT supported.

=head1 NGINX configuration (sample)

    location ~ ^/(cgi-)?bin/.*$ {
        expires epoch;
        gzip off;
        include /etc/nginx/fastcgi_params;
        fastcgi_param   SCRIPT_FILENAME $request_filename;
        fastcgi_pass    unix:/var/run/fcgid.sock;
    }

=head1 NOTES

Perl scripts can cache persistent data in $_{$0}->{mydata}
However if you store too much data it may trigger termination by rlimit
After DO/EVAL $_{$0}->{'SIGTERM'} being called so termination handler 
can be used to close DB connections etc.
    
    $_{$0}->{'SIGTERM'}=sub { print "I closed my handles"; };

=head1 FAQ

Why not fcgiwrap?
    fcgiwrap doesn't pass STDERR to web server for logging.
        
What's wrong with cgiwrap-fcgi.pl?  http://wiki.nginx.org/SimpleCGI
    Well, many things... 
        * It can't DO perl scripts.
        * It is written in a strange way which is hard to read and understand.
          Frankly, it is not very beautiful.
        * It takes no options so you have to modify the code.
        * It is incompatible with some CGI applications, notably with fossil.

=head1 AUTHOR

Dmitry Smirnov, C<< <onlyjob at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-fcgi-daemon at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=FCGI-Daemon>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

During development of this module a bug in Perl was discovered: http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=600376
http://rt.perl.org/rt3//Public/Bug/Display.html?id=78436

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc FCGI::Daemon

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker
    L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=FCGI-Daemon>

=item * AnnoCPAN: Annotated CPAN documentation
    L<http://annocpan.org/dist/FCGI-Daemon>

=item * CPAN Ratings
    L<http://cpanratings.perl.org/d/FCGI-Daemon>

=item * Search CPAN
    L<http://search.cpan.org/dist/FCGI-Daemon/>

=back

=head1 LICENSE

    FCGI::Daemon - FastCGI daemon
    Copyright (C) 2011 Free Software Foundation

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut


package Nagios::Config::Intelligent;

use 5.008008;
use strict;
use warnings;
use FileHandle;
use YAML;
require Exporter;
# use AutoLoader qw(AUTOLOAD);

our @ISA = qw(Exporter);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Nagios::Config::Intelligent ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw( ) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw( );
our $VERSION = '0.01';


# Preloaded methods go here.
sub new{
    my $class=shift;
    my $self={};
    my $cnstr=shift if @_;
    bless $self, $class;
    if(defined($cnstr->{'cfg'})){
        $self->nagioscfg($cnstr->{'cfg'});
    }
    # how our network is layed out  
    if(defined($cnstr->{'routers'})){
        $self->{'g'} = Graph::Network->new({ 'routers' => $cnstr->{'routers'} }); 
        #$self->{'g'}->draw("routers.png");
    }

    # how our nagios servrers are layed out { 'report' => $report, 'poll' => [ $poll[1] .. $poll[n] ] }
    if(defined($cnstr->{'topology'})){
        $self->{'nagios'} = YAML::LoadFile($cnstr->{'topology'});
        foreach my $host (@{ $self->{'nagios'}->{'poll'} }){
            $self->{'g'}->add_host({ 'name'    => $host, 'address' => $host }); # get the poll servers on the graph
        }
        foreach my $host (@{ $self->{'nagios'}->{'report'} }){
            $self->{'g'}->add_host({ 'name'    => $host, 'address' => $host }); # get the report servers on the graph
        }
    }

    # our nagios config files 
    if($self->nagioscfg){ 
        foreach ($self->object_files()){ $self->load_object_file($_); } 
    }
    if(defined($self->{'g'})){
        foreach my $host (@{ $self->{'objects'}->{'host'} }){
            $self->{'g'}->add_host({ 
                                     'name'    => $host->{'host_name'}, 
                                     'address' => $host->{'address'}     # should be an IP or resolve via DNS, full nsswitch unimplemented
                                  });  
        }
        foreach my $service (@{ $self->{'objects'}->{'service'} }){
            $self->{'g'}->add_service({ 
                                        'service_description' => $service->{'service_description'}, 
                                        'host_name'           => $service->{'host_name'}
                                     });  
        }
    }
    return $self;
}

sub hostgroup_members{
    my $self = shift;
    my $hostgroup_name = shift;
    my $hostgroup = $self->find_objects('hostgroup', { 'hostgroup_name' => $hostgroup_name });
    return undef unless defined($hostgroup->[0]);
    return undef unless defined($hostgroup->[0]->{'members'});
    return split(/,\s*/, $hostgroup->[0]->{'members'}); # you can't have a duplicate name, so this will be [0] or undef
}

################################################################################
# Assign active checks to the closest poll server and passive checks to the
# reporting server (if different from the poll server)
# 
sub delegate {
    my $self = shift;
    ############################################################################
    # handle the host entry foreach my $host (@{ $self->{'objects'}->{'host'} }){
    foreach my $host (@{ $self->{'objects'}->{'host'} }){
        my $poll_srv = $self->poll_server($host->{'address'});
        my $report_srv = $self->report_server($host->{'address'});

        # make a copy of the host check, de-template it
        my $active_check = $self->clone($self->detemplate($host,$self->{'templates'}->{'host'}));

        # actify the host check (strip out anything that makes it passive, add active traits)
        $active_check->{'active_checks_enabled'} = 1;
        delete($active_check->{'passive_checks_enabled'});
        if($poll_srv ne $report_srv){
            delete($active_check->{'notifications_enabled'});
            $active_check->{'notifications_enabled'} = 0;
        }

        # add it to the poll server's active work list
        push( @{ $self->{'work'}->{$poll_srv}->{'host'} },$active_check );

        if($poll_srv ne $report_srv){
            # copy the check for passive acceptance into the report host, de-template it
            my $passive_check = $self->clone($self->detemplate($host,$self->{'templates'}->{'host'}));

            # passify the host check (strip out anything that makes it active, add passive traits)
            delete($passive_check->{'active_checks_enabled'});
            $passive_check->{'passive_checks_enabled'} = 1;
            $passive_check->{'notifications_enabled'} = 1;

            # add the passive check to the report servers work list
            push( @{ $self->{'work'}->{$report_srv}->{'host'} }, $self->clone($passive_check) );
        }
    } 
    ############################################################################
    # service checks can be assigned to a hostgroup, so we need todereference 
    # those into atomic service checks here, replacing the entire service array.
    #
    my $new_services = [] ;
    foreach my $service (@{ $self->{'objects'}->{'service'} }){
        if(defined($service->{'host_name'})){
            push(@{ $new_services }, $service); 
        }elsif(defined($service->{'hostgroup_name'})){
            my @members = $self->hostgroup_members($service->{'hostgroup_name'});
            next unless @members;
            foreach my $host (@members){
                my $new_service = $self->clone($service); 
                delete $new_service->{'hostgroup_name'};
                $new_service->{'host_name'} = $host;
                push(@{ $new_services }, $new_service); 
            }
        }
    }
    # replace the global services list with our de-refereced one (yes, we've lost some information here, like the hostgroup alias)
    $self->{'objects'}->{'service'} = $self->clone($new_services);
    # 
    ############################################################################
    
    ############################################################################
    # now we process all service checks
    foreach my $service (@{ $self->{'objects'}->{'service'} }){
        next unless(defined( $service->{'host_name'} ));
        # get the host and poll host for this service
        my $host = $self->find_host({ 'host_name' => $service->{'host_name'} });
        my $poll_srv = $self->poll_server($host->{'address'}); 
        my $report_srv = $self->report_server($host->{'address'}); 

        # make a copy of the service check, de-template it
        my $service_check = $self->clone($self->detemplate($service,$self->{'templates'}->{'service'}));

        # actify the service check (strip out anything that makes it passive, add active traits)
        $service_check->{'active_checks_enabled'} = 1;
        delete($service_check->{'passive_checks_enabled'});
        if($poll_srv ne $report_srv){
            delete($service_check->{'notifications_enabled'});
            $service_check->{'notifications_enabled'} = 0;
        }

        # add the active check
        push( @{ $self->{'work'}->{$poll_srv}->{'service'} },$service_check );
       
        # and the passive check if the report server is not the poll server
        if($poll_srv ne $report_srv){
            # passify the service check (strip out anything that makes it active, add passive traits)
            my $passive_service_check = $self->clone($self->detemplate($service,$self->{'templates'}->{'service'}));

            delete($passive_service_check->{'active_checks_enabled'});
            $passive_service_check->{'passive_checks_enabled'} = 1;
            $passive_service_check->{'notifications_enabled'} = 1;

            push( @{ $self->{'work'}->{$report_srv}->{'service'} },$self->clone($passive_service_check) );
        }
    }    
}

sub report_server{
    # just in case we want to select a different report server for some cases later
    my $self = shift;
    my $target = shift;
    return $self->{'nagios'}->{'report'}->[0];
}

################################################################################
# Find the "appropriate" poll server for this host
# 
# if a 'poll' server is in the same network, use it.
# if not, count the networks from the each poll server to the monitored object
#   use the poll server with the least hops to the device, on a tie, use the 
#   one closet to the polling server
# a poll server may not monitor its own host status (except the report server)
#
sub poll_server{
    my $self = shift;
    my $target = shift;
    return undef unless $target;
    return $self->{'poll_server'}->{$target} if(defined($self->{'poll_server'}->{$target}));
    my $max_hops = 100000;
    my $closest_poller = undef;;
    foreach my $pollhost (@{ $self->{'nagios'}->{'poll'} }){
        my $hops = $self->{'g'}->network_trace( $pollhost, $target );
        $self->{'distance'}->{$target}->{$pollhost} =  $hops;
        if ($hops < $max_hops){ 
            $max_hops = $hops; 
            $closest_poller = $pollhost;
        }
    }
    if(defined($closest_poller)){
        # cache it for subsequent runs
        $self->{'poll_server'}->{$target} = $closest_poller;
        return $closest_poller;
    }
    $self->{'poll_server'}->{$target} = undef;
    return "indeterminite";
}

sub nagioscfg{
    my $self=shift;
    $self->{'nagioscfg'}=shift if @_;
    return $self->{'nagioscfg'};
}

# recursively return a list of nagios .cfg files per the nagios.cfg's cfg_dir directives
sub get_cfgs {
    my $self = shift;
    my $path    = shift;
    opendir (DIR, $path) or die "Unable to open $path: $!";
    my @files = map { $path . '/' . $_ } grep { !/^\.{1,2}$/ } readdir (DIR);
    # Rather than using a for() loop, we can just return a directly filtered list.
    return
        grep { (/\.cfg$/) && (! -l $_) }
        map { -d $_ ? get_cfgs ($_) : $_ }
        @files;
}

sub list_poll_only_servers{
    my $self = shift;
    my $pollers = [];
    foreach my $poll_server (@{ $self->{'nagios'}->{'poll'} }){
        push(@{ $pollers }, $poll_server) unless grep(/^$poll_server$/, @{ $self->{'nagios'}->{'report'} });
    }
    return $pollers;
}

sub list_report_servers{
    my $self = shift;
    return $self->{'nagios'}->{'report'};
}

sub nobject_isa{
   my $self = shift;
   my $nobject = shift;
   # nagios 2.x required attributes
   my $required_attributes = {
                               'command'           => [ 
                                                       'command_name', 
                                                       'command_line', 
                                                      ],
                               'contact'           => [ 
                                                       'contact_name', 
                                                       'alias', 
                                                       'host_notification_period', 
                                                       'service_notification_period', 
                                                       'host_notification_options', 
                                                       'service_notification_options', 
                                                       'host_notification_commands', 
                                                       'service_notification_commands', 
                                                      ],
                               'contactgroup'      => [ 
                                                       'contactgroup_name', 
                                                       'alias', 
                                                       'members', 
                                                      ],
                               'host'              => [ 
                                                        'alias', 
                                                        'address', 
                                                        'host_name', 
                                                        #'check_period',  # it will accept it without this even though the docs say it's "required"
                                                        'contact_groups', 
                                                        'max_check_attempts', 
                                                        'notification_interval',
                                                        'notification_period', 
                                                        'notification_options',
                                                      ],
                               'hostdependency'    => [ 
                                                       'dependent_host_name',
                                                       'host_name',
                                                      ],
                               'hostescalation'    => [ 
                                                        'host_name',
                                                        'contact_groups',
                                                        'first_notification',
                                                        'last_notification',
                                                        'notification_interval',
                                                      ],
                               'hostextinfo'       => [ 
                                                        'host_name',
                                                      ],
                               'hostgroup'         => [ 
                                                        'hostgroup_name',
                                                        'alias',
                                                        # 'members', # it will accept it without this even though the docs say it's "required"
                                                      ],
                               'service'           => [
                                                        'host_name',
                                                        'service_description',
                                                        'check_command',
                                                        'max_check_attempts',
                                                        'normal_check_interval', 
                                                        'retry_check_interval', 
                                                        'check_period', 
                                                        'contact_groups', 
                                                        'notification_interval',
                                                        'notification_period', 
                                                        'notification_options',
                                                      ],
                               'servicedependency' => [ 
                                                        'dependent_host_name',
                                                        'dependent_service_description',
                                                        'host_name',
                                                        'service_description',
                                                      ],
                               'serviceescalation' => [ 
                                                        'host_name',
                                                        'service_description',
                                                        'contact_groups',
                                                        'first_notification',
                                                        'last_notification',
                                                        'notification_interval',
                                                      ],
                               'serviceextinfo'    => [ 
                                                        'host_name',
                                                        'service_description',
                                                      ],
                               'servicegroup'      => [ 
                                                        'servicegroup_name',
                                                        'alias',
                                                        'members',
                                                      ],
                               'timeperiod'        => [ 
                                                        'timeperiod_name', 
                                                        'alias', 
                                                      ],
                             };
   # find the nagios object types for which all required attributes are present, 
   # if more than one match, (serviceextinfo's reqs are a sub-set of service) 
   # favor the one with the most matches.
   my $max_matched=-1;
   my $type = undef;
   foreach my $obj_type (keys(%{ $required_attributes })){
       my $matched=-1;
       foreach my $req (@{ $required_attributes->{$obj_type}  }){
           if(defined($nobject->{$req})){ $matched++; }
       }
       # Determine if the required objects were all matched
       if($matched == $#{ $required_attributes->{$obj_type}  }){ 
           if($matched > $max_matched){ 
               $type = $obj_type;
               $max_matched = $matched;
           }
       }
   }
   return $type if(defined($type));
   print STDERR Data::Dumper->Dump([{ 'unknown object' => $nobject }]); 
   return 'unknown';
}

# $self->write_object_cfg($obj_list_ref, $filename);
sub write_object_cfg{
    my $self        = shift;
    my $objects     = shift;
    my $filename    = shift;
    my $append      = shift if @_;
    $objects = [ $objects ] unless(ref($objects) eq 'ARRAY');

    # determine the longest key for readability of the configs
    my $max_key_length = undef;
    foreach my $object (@{ $objects }){
        my $object_type = $self->nobject_isa($object);
        foreach my $key (keys(%{ ${object} })){
            if(! defined($max_key_length)){
                $max_key_length=length($key);
            }elsif(length($key) > $max_key_length){
                $max_key_length=length($key) 
           }
        }
    }

    # write out the objects into the file
    my $fh = undef;
    if($append){
        $fh = FileHandle->new(">> $filename");
    }else{
        $fh = FileHandle->new("> $filename");
    }
    if (defined $fh) {
        foreach my $object (@{ $objects }){
            my $object_type = $self->nobject_isa($object);
            print $fh "define $object_type {\n";
            foreach my $key (keys(%{ ${object} })){
                print $fh "    $key";
                for(my $i=0; $i<=$max_key_length-length($key); $i++){ print $fh " "; }
                print $fh "$object->{$key}\n";
            }
            print $fh "}\n\n";
        }
        $fh->close;
    } 
}

sub write_templates{
    my $self = shift;
    my $path = shift if @_;
    return undef unless(defined($path));
    if(! -d "$path"){ mkdir($path,0755); }
    if(! -d "$path"){ 
        print STDERR "Unable to create $path.\n";
        return undef;
    }
    foreach my $type (keys(%{ $self->{'templates'} })){
        # $fh = FileHandle->new("> $path/$type");
        # if (defined $fh) {
        #     print $fh "bar\n";
        #     $fh->close;
        # }
        YAML::DumpFile("$path/$type.cfg",$self->{'templates'}->{$type});
    }
}

sub write_object_cfgs{
    my $self = shift; 
    my $cnstr = shift;
    if(defined($cnstr->{'dir'})){
        if(! -d "$cnstr->{'dir'}"){ mkdir("$cnstr->{'dir'}"); }
        if(! -d "$cnstr->{'dir'}"){ return undef; }
        if(! -w "$cnstr->{'dir'}"){ return undef; }
        # for each nagios poll server
        #         for each host create <host>.cfg in objects dir with  write out host check
        #             for each service for that host, append active service checks
        #
        foreach my $pollsrv (@{ $self->list_poll_only_servers }){
            if(! -d "$cnstr->{'dir'}/$pollsrv"){ mkdir("$cnstr->{'dir'}/$pollsrv"); }
            if(! -d "$cnstr->{'dir'}/$pollsrv/nobjects.d"){ mkdir("$cnstr->{'dir'}/$pollsrv/nobjects.d"); }
            ################################################################################
            # dump the templates (they're global)
            $self->write_templates("$cnstr->{'dir'}/$pollsrv/templates.d");
            # write out non-host configs (commands, contact, contactgroup)
            foreach my $object_type (keys(%{ $self->{'objects'} })){
                next unless $object_type;
                next if(grep(
                              /$object_type/, 
                              (
                                'host',
                                'service',
                                # these really only mean something on the report server
                                'hostextinfo', 
                                'hostgroup',
                                'hostdependency',
                                # as do these
                                'serviceextinfo',
                                'servicegroup',
                                'servicedependency'
                             )));
                $self->write_object_cfg($self->{'objects'}->{$object_type},       "$cnstr->{'dir'}/$pollsrv/$object_type.cfg");

                ############################################################################
                # service and host objects are treated differently, 
                # we write these out to objects.d/<fqdn>.cfg host checks then service checks
                # then hostextinfo, serviceextinfo, hostdependencies, servicedependencies,
                foreach my $host_nobject (@{ $self->{'work'}->{$pollsrv}->{'host'} }){
                    $self->write_object_cfg($host_nobject,"$cnstr->{'dir'}/$pollsrv/nobjects.d/".$host_nobject->{'host_name'}.".cfg");

                    foreach my $service_nobject (@{ $self->{'work'}->{$pollsrv}->{'service'} }){
                        next if ($service_nobject->{'host_name'} ne $host_nobject->{'host_name'});
                        $self->write_object_cfg($service_nobject,"$cnstr->{'dir'}/$pollsrv/nobjects.d/".$host_nobject->{'host_name'}.".cfg",1);
                    }
                }
            }
            ################################################################################
        }
        # for each nagios report server,
        #     write out non-host configs (commands, contact, contactgroup)
        #         for each host create <host>.cfg in objects dir with  write out host check, hostextinfo, hostdependencies
        #             for each service for that host, append (active and passive) service checks, serviceextinfo, servicedependencies
        foreach my $reportsrv (@{ $self->list_report_servers }){
            if(! -d "$cnstr->{'dir'}/$reportsrv"){ mkdir("$cnstr->{'dir'}/$reportsrv"); }
            if(! -d "$cnstr->{'dir'}/$reportsrv/nobjects.d"){ mkdir("$cnstr->{'dir'}/$reportsrv/nobjects.d"); }
            ################################################################################
            # dump the templates (they're global)
            $self->write_templates("$cnstr->{'dir'}/$reportsrv/templates.d");
            #     write out non-host configs (commands, contact, contactgroup)
            foreach my $object_type (keys(%{ $self->{'objects'} })){
                next unless $object_type;
                next if(grep( 
                              /$object_type/,
                              (
                                'host',
                                #'hostextinfo',
                                #'hostgroup',
                                #'hostdependency',
                                'service',
                                #'serviceextinfo',
                                #'servicegroup',
                                #'servicedependency'
                             )));
                $self->write_object_cfg($self->{'objects'}->{$object_type},         "$cnstr->{'dir'}/$reportsrv/$object_type.cfg");
                ############################################################################
                # service and host objects are treated differently, 
                # we write these out to objects.d/<fqdn>.cfg host checks then service checks
                # then hostextinfo, serviceextinfo, hostdependencies, servicedependencies,
                foreach my $host_nobject (@{ $self->{'work'}->{$reportsrv}->{'host'} }){
                    $self->write_object_cfg($host_nobject,"$cnstr->{'dir'}/$reportsrv/nobjects.d/".$host_nobject->{'host_name'}.".cfg");

                    foreach my $service_nobject (@{ $self->{'work'}->{$reportsrv}->{'service'} }){
                        next if ($service_nobject->{'host_name'} ne $host_nobject->{'host_name'});
                        $self->write_object_cfg($service_nobject,"$cnstr->{'dir'}/$reportsrv/nobjects.d/".$host_nobject->{'host_name'}.".cfg",1);
                    }
                }
            }
        }
    }
}

# return a list of nagios config files per the nagios.cfg cfg_file & cfg_dir directives
sub object_files {
    my $self = shift;
    my $nagios_cfg = $self->{'nagioscfg'}||"/etc/nagios/nagios.cfg";
    return undef unless(-f $nagios_cfg);
    my $fh = FileHandle->new;
    my @cfg_files;
    if ($fh->open("< $nagios_cfg")) {
        while(my $line=<$fh>){
            chomp($line);
            $line=~s/#.*//;
            next if($line=~m/^\s*$/);
            next unless($line=~m/^\s*cfg_(file|dir)\s*=(.*)$/);
            if($1 eq "file"){
                push(@cfg_files,$2);
            }elsif($1 eq "dir"){
                push(@cfg_files,$self->get_cfgs($2));
            }
        }
        $fh->close;
    }
    return @cfg_files;
}

# load one or many object files
sub load_object_files{
    my $self = shift;
    my $files=shift if @_;
    if(ref($files) eq 'SCALAR'){
        $self->load_object_file($files);
    }elsif(ref($files) eq 'ARRAY'){
        foreach my $file (@{ $files }){
            $self->load_object_file($file);
        }
    }else{
        print STDERR "unknown or unexpected reference type $!:\n";  
    }
    return $self;
}

# load one object file
sub load_object_file{
    my $self = shift;
    my $file=shift if @_;
    my $fh=new FileHandle->new; 
    if($fh->open("< $file")){
       while(my $line=<$fh>){
       chomp($line) if $line;
           $line=~s/#.*//g;
           $line=~s/^\s+$//g;
           next if $line=~m/^$/;
           if($line=~m/\s*define\s+(\S+)\s*{(.*)/){
               my $object_type=$1;
               my $definition="$line\n";
               # read the file until the parenthesis is balanced
               while( ($self->unbalanced($definition)) && ($definition.=<$fh>) ){}
               $definition=~s/^[^{]+{//g;
               $definition=~s/}[^}]*//g;
               my @keyvalues=split(/\n/,$definition);
               my $record = {};
               foreach my $entry (@keyvalues){
                   # remove comments at the beginning of the line FIXME comments can be at the ends of lines too.
                   $entry=~s/\s*[;#].*$//;
                   next if($entry=~m/^\s*$/);
                   # remove leading/trailing whitespace
                   $entry=~s/^\s*//;
                   $entry=~s/\s*$//;
                   # break down the key/value pairs 
                   if($entry=~m/(\S+)\s+(.*)/){
                       my ($key,$value) = ($1,$2);
                       $record->{$key} = $value;
                   }else{
                       print STDERR "NOT SURE ABOUT:  $entry\n";
                   }
               }
               # we have to separate templates from objects, and save them by name, or we end up with infinite recursion
               # what we *really* need instead is recursion depth detection in find_object
               if( defined($record->{'name'}) && defined($record->{'register'}) && ($record->{'register'} == 0)){
                   $self->{'templates'}->{$object_type}->{ $record->{'name'} } = $record;
               }else{
                   push(@{ $self->{'objects'}->{$object_type} },$record);
               }
               undef $record;
           }
       }
    $fh->close;
    }
    return $self;
}

sub unbalanced{
    my $self=shift;
    my $string=shift;
    my $balance=0;
    my @characters=split(//,$string);
    foreach my $c (@characters){
        if($c eq '{'){ $balance++ };
        if($c eq '}'){ $balance-- };
    }
    return $balance;
}

sub dump{
    my $self = shift;
    print YAML::Dump($self);
    return $self;
}

sub load_status{
    my $self=shift;
    return undef if(!defined($self->{'config'}->{'status_file'}));
    my $fh=new FileHandle->new;
    if($fh->open("< $self->{'config'}->{'status_file'}")){
       while(my $line=<$fh>){
           chomp($line) if $line;
           $line=~s/#.*//g;
           $line=~s/^\s+$//g;
           next if $line=~m/^$/;
           if($line=~m/\s*(\S+)\s*{\s*$/){
               my $item=$1;
               my $definition="$line\n";
               # read the file until the parenthesis is balanced
               while( ($self->unbalanced($definition)) && ($definition.=<$fh>) ){}
               $definition=~s/^[^{]+{//g;
               $definition=~s/}[^}]*//g;
               my @keyvalues=split(/\n/,$definition);
               my $record = {};
               my $record_name = undef;
               foreach my $entry (@keyvalues){
                   # remove hash comments /* FIXME this shoulde be unquoted hashmarks */
                   $entry=~s/#.*$//;
                   # remove semicolon comments /* FIXME this shoulde be unquoted semicolons */
                   $entry=~s/;.*$//;
                   next if($entry=~m/^\s*$/);
                   # remove leading/trailing whitespace
                   $entry=~s/^\s*//;
                   $entry=~s/\s*$//;
                   # break down the key/value pairs
                   if($entry=~m/(\S+)\s*=\s*(.*)/){
                       my ($key,$value) = ($1,$2);
                       $record->{$key}=$value;
                   }
               }
               if($item eq "info"){
                   if(defined($self->{'status'}->{$item})){
                       if($self->{'status'}->{$item}->{'created'} == $record->{'created'}){
                           print STDERR "status has not changed since last parse\n";
                           $fh->close;
                           return $self;
                       }
                   }
                   $self->{'status'}->{$item}=$record;
               }elsif($item eq "program"){
                   $self->{'status'}->{$item}=$record;
               }elsif($item eq "host"){
                   $self->{'status'}->{'host'}->{ $record->{'host_name'} } = $record;
               }elsif($item eq "service"){
                   push(@{ $self->{'status'}->{'service'}->{ $record->{'host_name'} } },$record);
               }else{
                    print STDERR "unknown item in status file [$item]\n";
               }
           }
       }
       $fh->close;
    }
    return $self;
}

sub find_contact{
    my $self=shift;
    my $attrs=shift if @_;
    return $self->find_object('contact',$attrs);
}

sub find_host{
    my $self=shift;
    my $attrs=shift if @_;
    return $self->find_object('host',$attrs);
}

sub find_service{
    my $self=shift;
    my $attrs=shift if @_;
    return $self->find_object('service',$attrs);
}

sub entry_name{
    my $self = shift;
    my $entry = shift;
    foreach my $key (keys(%{ $entry })){
        # everything should have either a "name" or "service_name" or "host_name" or "*_name"
        if($key eq 'name'){ return $entry->{'name'}; }
        if($key =~m/(.*_name)$/){ return $entry->{$1}; }
    }
    return undef;
}

sub clone {
    my $self = shift;
    my $object = shift;
    return undef unless $object;
    return YAML::Load(YAML::Dump($object));
}

################################################################################
# given an object and a hash of templates, 
# iteratively dereference the object until no template references remain
#
sub detemplate{
    my ($self, $entry, $templates) = @_;
    return $entry unless(defined($entry->{'use'}));
    unless(defined($templates)){
        print STDERR "no templates provided\n";
        return $entry;
    }
    # de-template the template if it uses one
    my $template;
    if(defined($templates->{ $entry->{'use'} })){
        $template = $self->clone( $self->detemplate($templates->{ $entry->{'use'} }, $templates) );
    }else{
        $template = undef;
        warn "no such template: $entry->{'use'}\n";
        return $entry;
    }

    # start the new entry with the fetched template
    my $new_entry = $self->clone($template);

    # override the template with entries from the entry being templated
    foreach my $key (keys(%{ $entry })){
        $new_entry->{$key} = $entry->{$key};
    }

    # get rid of all the things that indicate this entry is a template
    delete $new_entry->{'name'} if( defined($new_entry->{'name'}) ); # lose the template name
    delete $new_entry->{'register'} if( defined($new_entry->{'register'}) && ($new_entry->{'register'} == 0));
    delete $new_entry->{'use'} if(defined($new_entry->{'use'})); 
    return $new_entry;
}

sub find_objects{
    my $self = shift;
    my $type = shift if @_;   # the type of entry we're looking for (e.g. 'contact', 'host', 'servicegroup', 'command')
    my $attrs = shift if @_;  # a hash of the attributes that *all* must match to return the entry/entries
    my $records = undef;      # the list we'll be returning
    foreach my $entry (@{ $self->{'objects'}->{$type} }){
        if(defined($entry->{'use'})){
            $entry = $self->detemplate($entry,$self->{'templates'}->{$type});
        }
        my $allmatch=1;       # assume everything matches
        foreach my $needle (keys(%{ $attrs })){
            if(defined($attrs->{$needle})){ # how is this ever not the case? And yet, errors.
                if(defined($entry->{$needle})){
                    unless($entry->{$needle} eq $attrs->{$needle}){
                        $allmatch=0; # if the key's value we're looking for isn't the value in the entry, then all don't match
                    }
                }else{
                    $allmatch=0; # if we're missing a key in the attrs, then all don't match
               }
            }else{
                $allmatch=0; # if we're missing a key in the attrs, then all don't match
            }
        }
        if($allmatch == 1){  # all keys were present, and matched the values for the same key in $attrs
            push(@{ $records },$entry);
        }
    }
    return $records; # return the list of matched entries
}

sub find_object{
    my $self = shift;
    my $type = shift if @_;   # the type of entry we're looking for (e.g. 'contact', 'host', 'servicegroup', 'command')
    my $attrs = shift if @_;  # a hash of the attributes that *all* must match to return the entry/entries
    my $objects = $self->find_objects($type,$attrs);
    if($#{ $objects } > 0){
        print STDERR "multiple objects matche the search, only returning the first\n";
        return shift(@{$objects});
    }elsif($#{ $objects } == 0){
        return shift(@{$objects});
    }else{
        print STDERR "no objects found matching search\n";
        #print STDERR Data::Dumper->Dump([{
        #                                   'type' => $type,
        #                                   'attrs' => $attrs,
        #                               }]);
        return undef;
    }
}

sub find_object_regex{
    my $self = shift;
    my $type = shift if @_;   # the type of entry we're looking for (e.g. 'contact', 'host', 'servicegroup', 'command')
    my $attrs = shift if @_;  # a hash of the attributes that *all* must match to return the entry/entries
    my $records = undef;      # the list we'll be returning
    foreach my $entry (@{ $self->{'objects'}->{$type} }){
        if(defined($entry->{'use'})){
            $entry = $self->detemplate($entry,$self->{'templates'}->{$type});
        }
        my $allmatch=1;       # assume everything matches
        foreach my $needle (keys(%{ $attrs })){
            if(defined($entry->{$needle})){
                unless($entry->{$needle}=~m/$attrs->{$needle}/){
                    $allmatch=0; # if the key's value we're looking for isn't the value in the entry, then all don't match
                }
            }else{
                $allmatch=0; # if we're missing a key in the attrs, then all don't match
            }
        }
        if($allmatch == 1){  # all keys were present, and matched the values for the same key in $attr
            push(@{ $records },$entry);
        }
    }
    return $records; # return the list of matched entries
}


#################################################################################
## Get statuses from the status.dat
#################################################################################
sub host_status{
    my $self=shift;
    my $hostname=shift;
    my $records = undef;
    $self->load_status() unless( defined ($self->{'status'}) );
    return $self->{'status'}->{'host'}->{$hostname} if(defined($self->{'status'}->{'host'}->{$hostname}));
    return undef;
} 

sub service_status{
    my $self=shift;
    my $attrs=shift if @_;
    my $records = undef;
    my $allmatch;
    $self->load_status() unless( defined ($self->{'status'}) );
    foreach my $host (keys(%{ $self->{'status'}->{'service'} })){
        foreach my $service (@{ $self->{'status'}->{'service'}->{$host} }){
            $allmatch=1;
            foreach my $needle (keys(%{ $attrs })){
                if(defined($service->{$needle})){
                    if($service->{$needle} ne $attrs->{$needle}){
                        # They don't match if they don't match...
                        $allmatch=0;
                    }
                }else{
                    # They obviously don't match if it's not defined.
                    $allmatch=0;
                }
            }
            if($allmatch == 1){
                push(@{ $records }, $service);
            }
        }
    }
    return $records;
}

# find the key/value pairs that the listref of hashrefs have in common
sub intersection {
    my $self=shift;
    my ($sets) = shift;
    my $i = shift(@{ $sets });; # the first one intersects fully with itself;
    my $intersection = $self->clone($i); # make a copy
    while(my $next = shift(@{ $sets })){
        foreach my $key (keys(%{ $intersection })){ # remove things in intersection that are not in next
            if( (!defined($next->{$key})) || ($intersection->{$key} ne $next->{$key}) ){
                delete $intersection->{$key};
            }
        }
    }
    return $intersection;
}

# search a list of hashes for that hash return 1 if it's in there
sub already_in{
    my $self = shift;
    my $list = shift;
    my $hash = shift;
    my $elements = keys(%{ $hash });
    my $found_it=0;
    foreach my $h (@{ $list }){
        my $intersection = $self->intersection([$h, $hash]);
        my $count = keys(%{ $intersection });
        if($elements == $count){ return 1; }
    }
    return 0;
}

################################################################################
# add a new template unless one exists that matches everything but "name" and "register"
# add it with a name of <type>_NNNN where NNNN is the next number that doesn't exist as
# a template, and ensure "register 0" is set.
#
# $new_templates = $self->add_template($old_templates,$template_to_add);
sub add_template{
    my ($self,$templates,$new_template,$type) = @_;
    return $templates unless $templates;
    return $templates unless $new_template;
    my $max_nnnn = 0000;
    foreach my $tname (keys(%{ $templates })){
        my $already_have = 0;
        if($tname=~m/${type}_([0-9]+)/){ $max_nnnn = $1 if($1 > $max_nnnn); } # get the max name so we can increment
        my $template = $self->clone($templates);
        delete $template->{'name'} if $template->{'name'};
        delete $template->{'register'} if $template->{'register'};
        my $existing_count = keys(%{ $template });
        my $new_count = keys(%{ $new_template });
        next unless($existing_count == $new_count); # they don't match if they have different key counts
        my $intersection = $self->intersection([$template, $new_template]); 
        my $i_count=keys(%{ $intersection });

        # if their intersection key count is the same as the other two counts, we already have this template
        if($i_count == $new_count){ 
            return $templates;
        }  
    }
    # at this point we don't have already have the template or we would have returned the template name, so we add it
    $max_nnnn++;
    $new_template->{'name'} = "${type}_$max_nnnn";
    $new_template->{'register'} = "0";
    $templates->{ $new_template->{'name'} } = $new_template;
    return $templates;
}

################################################################################
# given a list of objects, and optionally, a list of templates:
# 1) de-template all the objects using the templates provided

# 2) create a matrix of commonalities between all (de-templated) entries
# so if we have 5 sets [a, b, c, d, e] and they each have say, 9 elements, 
# we'll get a matrix that looks like:
# _ a b c d e
# a 9 _ _ _ _
# b 5 9 _ _ _
# c 4 5 9 _ _
# d 5 5 4 9 _
# e 0 4 4 5 9

# 3) we then create template_candidates from each of thes numbers
# 4) we check each of them against the existing contact templates, 
#    adding them to the templates list (if they don't exist.)

# 5) we can then (for each object, iterate through the templates, 
#    find the one that matches the best, tell the object to "use"
#    it and remove it's key/value pairs from the object

# We're left with a normalized list of objects and a 
# (hopefully) larger list of templates, which we return in the hash:
# { 'objects' => [ ..list of objects.. ], 'templates' => [ ..list of templates.. ] }
################################################################################
# $self->reduce({ 'objects' => [], 'templates' => {} });
#
sub reduce {
    my $self = shift;
    my $inputs = shift if @_;    
    return $inputs unless (defined($inputs->{'objects'}));

    my $objects = $inputs->{'objects'};         # a list of similar objects type
    my $type_check = {};

    ############################################################################
    # type detection
    # sometimes the nagios configs are too sloppy to be detected, so we use some 
    # democracy here. iterate over the objects, find the most common type.
    # this should work for "sloppy" but not for "completely fucked"
    #
    foreach my $o (@{ $objects }){ 
        $type_check->{ $self->nobject_isa($o) }++;
    }
    my $type = undef;
    my $max=-1; 
    foreach my $k (keys(%{ $type_check })){
        if($type_check->{$k} > $max){
            $max = $type_check->{$k};
            $type = $k;
        }
    }
    print STDERR "  type of [ $type ] detected.\n";

    ############################################################################
    #
    my $templates = $inputs->{'templates'}||{}; # the existing templates for this object type to reduce against

    my $sets = $self->clone($objects); # make a copy
    my $template_candidates;           # where we will add possible new templates

    # get an intersection count for every pair of objects, push these intersections into $template_candidtates
    for(my $i=0; $i<=$#{$sets};$i++){
        for(my $j=0; $j<=$i;$j++){
            my $intersection = $self->clone($sets->[$i]);

            # we don't want to intersect on host_name if this is a service, would result in not enough normalization
            delete $intersection->{'host_name'} if( $type eq 'service');

            my $s_count = keys(%{ $intersection });
            foreach my $key (keys(%{ $intersection })){
                if( (!defined($sets->[$j]->{$key})) || ($intersection->{$key} ne $sets->[$j]->{$key}) ){
                    delete $intersection->{$key}; # remove things in intersection that are not in the set being compared
                }
            }
            my $i_count = keys(%{ $intersection });
            if($i_count < $s_count){ # only a candidate if it actually reduced
                push(@{ $template_candidates }, $intersection) unless $self->already_in($template_candidates,$intersection);
            }
            my @incommon = keys(%{ $intersection });
        }
    }

    # look through our template candidates, strip out the type_name
    foreach my $tpl (@{ $template_candidates }){
        if(defined($type)){
            delete $tpl->{$type.'_name'} if(defined($tpl->{$type.'_name'}));
        }else{
            # template_detection failed (not all required attrs are required in a template)  manually remove the name
            foreach my $k (keys(%{$tpl})){
                delete $tpl->{$k} if($k=~m/_name$/);
            }
        }
        # promote the candidate to a full template if it has more than 4 keys
        # (if you don't remove 4 lines, you're adding lines)
        $templates = $self->add_template($templates,$tpl,$type) if(keys(%{ $tpl }) >= 4); 
    }

    # now we want to reduce the actual object by the largest template of it's type that will fit it.
    my $object_entry;

    for(my $i=0; $i<=$#{ $objects };$i++){
        my $type = $self->nobject_isa( $objects->[$i] );
        my $biggest_count = 0;
        my $biggest_name = undef;
        # for each template of this type
        foreach my $tpl_name (keys(%{ $self->{'templates'}->{$type} })){
           # make a copy...
           my $tmpl = $self->clone($self->{'templates'}->{$type}->{$tpl_name});
           # remvove the items that make it a template from the clone
           delete $tmpl->{'name'} if(defined($tmpl->{'name'}));
           delete $tmpl->{'host_name'} if(defined($tmpl->{'host_name'}));
           delete $tmpl->{'register'} if(defined($tmpl->{'register'}));
           # get an element count
           my $t_elements = keys(%{ $tmpl });
           #get an element count of the items in this template that intersect with $objects->[$i]
           if(defined($objects->[$i]->{'use'})){
               $object_entry = $self->detemplate($objects->[$i], $self->{'templates'}->{$type} ); # expand the object in case it's already templated
           }else{
               $object_entry = $self->clone($objects->[$i] ); # expand the object in case it's already templated
           }
           my $intersect = $self->intersection([ $tmpl, $object_entry ]);
           # print Data::Dumper->Dump([{
           # 'comparing' => [ $tmpl, $objects->[$i] ],
           # 'actually' => [ $tmpl, $object_entry ],
           # 'result' => [ $intersect ],
           # }]);
           my $i_elements = keys(%{ $intersect });
           if ($i_elements == $t_elements){ # all of these match, and it's the biggest, save the name
               if($biggest_count < $i_elements){
                   $biggest_count=$i_elements;
                   $biggest_name=$tpl_name;
               }
           }
        }
        # at this point we should have the entry, and the template it can be reduced by ind $tpl_name
        #print STDERR Data::Dumper->Dump([{ 'biggest_name' => $biggest_name }]);
        if(defined($biggest_name)){
            foreach my $tplkey (keys(%{ $self->{'templates'}->{$type}->{$biggest_name} })){
                delete $object_entry->{$tplkey} if(defined($object_entry->{$tplkey}));
            }
            $object_entry->{'use'} = $biggest_name;
            $sets->[$i] = $self->clone($object_entry);
        }
    }
    print Data::Dumper->Dump([{ 'objects' => $sets, 'templates' => $templates }]);
    return $inputs = { 'objects' => $sets, 'templates' => $templates };
}
## Autoload methods go after =cut, and are processed by the autosplit program.
#
1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Nagios::Config::Intelligent - Perl extension for blah blah blah

=head1 SYNOPSIS

  use Nagios::Config::Intelligent;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for Nagios::Config::Intelligent, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

James S. White, E<lt>jameswhite@localdomainE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by James S. White

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.


=cut


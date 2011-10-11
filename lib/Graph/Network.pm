# yum install -y graphviz graphviz-gd graphviz-perl
package Graph::Network;
use strict;
use YAML;
use Graph::Directed;
use Graph::Writer::Dot;
use Net::CIDR;
use Net::DNS;

sub new{
    my $class=shift;
    my $self={};
    my $cnstr=shift if @_;
    bless $self, $class;

    $self->{'g'} = Graph::Directed->new; # A directed graph.
    $self->{'res'} = Net::DNS::Resolver->new;
    $self->{'debug'} = $cnstr->{'debug'}||0;
    
    if(defined($cnstr->{'routers'})){
        if( -f "$cnstr->{'routers'}"){
            $self->{'routers'} = YAML::LoadFile("$cnstr->{'routers'}");
        } 
    }
    if(defined($self->{'routers'})){
        foreach my $router (@{ $self->{'routers'}}){
            $self->add_router($router);
        }
    }
    return $self;
}

sub debug{
    my $self = shift;
    my $message = shift;
    print STDERR "$message\n" if $self->{'debug'};
}

################################################################################
# create a graph of the network using the interfaces on therouters provided
# [hostA]<--->[hostA:eth0]<-->[hostB:eth0]<-->[hostB]<-->[hostB:eth1]<-->( etc. )
#
sub add_router{
    my $self = shift;
    my $router = shift if @_;
    return $self unless $router;

    ############################################################################
    # add the router itself as a vertex
    if(defined($router->{'name'})){
        $self->debug("adding vertex $router->{'name'}");
        $self->{'g'}->add_vertex($router->{'name'}) unless $self->{'g'}->has_vertex($router->{'name'});
    }
    ############################################################################
    # add each interface on the router as a vertex, with bi-directional edges to 
    # the router itself (i.e. basalt:wan <-> basalt <-> basalt:lan
    foreach my $router_if (@{ $router->{'interface'} }){
        if(defined($router->{'name'}) && defined($router_if->{'name'})){
            # add the interface edge
            $self->debug("adding vertex $router->{'name'}:$router_if->{'name'}");
            $self->{'g'}->add_vertex($router->{'name'}.':'.$router_if->{'name'})
              unless $self->{'g'}->has_vertex($router->{'name'}.':'.$router_if->{'name'});
            # add the edge between host and host:interface
            $self->debug("adding edge between $router->{'name'} and $router->{'name'}:$router_if->{'name'}");
            $self->{'g'}->add_edge($router->{'name'},$router->{'name'}.':'.$router_if->{'name'});
            # (both directions)
            $self->{'g'}->add_edge($router->{'name'}.':'.$router_if->{'name'},$router->{'name'});
            ####################################################################
            # get the IP and netmask for CIDR calculations
            my ($interface_ip,$netbits) = split(/\//,$router_if->{'ip'});
            my ($network, $broadcast)=split(/-/,join('',Net::CIDR::cidr2range($router_if->{'ip'})));
            ####################################################################
            # complete the graph segment by attaching the interface to the network it's on:
            # [192.168.21.0/24] <-> [basalt:lan] <-> [basalt] <-> [basalt:wan] <-> [198.51.100.32/29]
            $self->debug("adding vertex $network/$netbits");
            $self->{'g'}->add_vertex($network."/".$netbits) unless $self->{'g'}->has_vertex($network."/".$netbits);
            # add edges to/from the hostname:interface to the network
            $self->debug("adding edge between $router->{'name'}:$router_if->{'name'} and  $network/$netbits");
            $self->{'g'}->add_edge($network."/".$netbits, $router->{'name'}.':'.$router_if->{'name'});
            $self->{'g'}->add_edge($router->{'name'}.':'.$router_if->{'name'}, $network."/".$netbits);
        }
    }
    return $self;
}

################################################################################
# add a host to our existing graph of routers
#
sub add_host{
    my $self = shift;
    my $hostdata = shift if @_;
    return undef unless $hostdata->{'name'}; 
    $hostdata->{'address'} = $hostdata->{'name'} unless(defined($hostdata->{'address'}));
    # add the vertex for our host
    # look up the ip if the address is a hostname
    if($hostdata->{'address'}=~m/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/){
        $self->{'g'}->add_vertex($hostdata->{'name'}) unless $self->{'g'}->has_vertex($hostdata->{'name'});
        #print "Added $hostdata->{'name'}\n" if  $self->{'g'}->has_vertex($hostdata->{'name'});
        $self->{'g'}->add_vertex("$hostdata->{'name'}:$hostdata->{'address'}") 
          unless $self->{'g'}->has_vertex("$hostdata->{'name'}:$hostdata->{'address'}");
        $self->{'g'}->add_edge($hostdata->{'name'},"$hostdata->{'name'}:$hostdata->{'address'}");
        $self->{'g'}->add_edge("$hostdata->{'name'}:$hostdata->{'address'}",$hostdata->{'name'});
        #print "Added $hostdata->{'name'}:$hostdata->{'address'}\n" if  $self->{'g'}->has_vertex("$hostdata->{'name'}:$hostdata->{'address'}");
    }else{
        $hostdata->{'address'} = $self->ipaddress($hostdata->{'address'});
        if($hostdata->{'address'}=~m/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/){
            $self->{'g'}->add_vertex($hostdata->{'name'}) unless $self->{'g'}->has_vertex($hostdata->{'name'});
            $self->{'g'}->add_vertex("$hostdata->{'name'}:$hostdata->{'address'}") 
              unless $self->{'g'}->has_vertex("$hostdata->{'name'}:$hostdata->{'address'}");
            $self->{'g'}->add_edge($hostdata->{'name'},"$hostdata->{'name'}:$hostdata->{'address'}");
            $self->{'g'}->add_edge("$hostdata->{'name'}:$hostdata->{'address'}",$hostdata->{'name'});
        }else{
            print STDERR "Unable to determine numeric IP for address [$hostdata->{'address'}]. It will be omitted from the graph.\n"; 
        }
    }
    # add the vertex for the host:ip (we won't know from the nagios configs what the name of the interface is)
    # add the edges between the host <==> host:ip
    # add the edges between the host:ip <==> cidr
    return $self;
}

sub add_service{
    my $self = shift;
    my $hostdata = shift if @_;
    return undef unless $hostdata->{'name'}; 
    return undef unless $hostdata->{'address'};
    # add the vertex & edges for our host if not exist
    # add the edge for host_name <==> host_name:service_description
}


sub ipaddress{
    use Net::DNS;
    my $self = shift;
    my $hostname = shift;
    my $res = Net::DNS::Resolver->new; 
    my $query = $res->search($hostname);
    
    return "127.0.0.1";
}

sub draw{
   my $self = shift;
   my $file = shift if @_;
   return undef unless $file;
   my $writer = Graph::Writer::Dot->new();
   $writer->write_graph($self->{'g'}, $file.".dot");
   system("/usr/bin/dot -Tpng ".$file.".dot -o $file");
   #system("/bin/rm $file.dot");
   return $self;
}

1;

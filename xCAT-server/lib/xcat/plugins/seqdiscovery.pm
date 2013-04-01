#!/usr/bin/env perl
## IBM(c) 20013 EPL license http://www.eclipse.org/legal/epl-v10.html
#
# This plugin is used to handle the sequencial discovery. During the discovery,
# the nodes should be powered on one by one, sequencial discovery plugin will 
# discover the nodes one by one and  define them to xCAT DB. 

# For the new discovered node but NOT handled by xCAT plugin, 
# it will be recorded to discoverydata table.
#

package xCAT_plugin::seqdiscovery;
BEGIN
{
    $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}

use strict;
use Getopt::Long;

use lib "$::XCATROOT/lib/perl";
use xCAT::NodeRange;
use xCAT::Table;
use xCAT::NetworkUtils;
use xCAT::MsgUtils;
use xCAT::DiscoveryUtils;

use Time::HiRes qw(gettimeofday sleep);

sub handled_commands {
    return {
        findme => 'seqdiscovery',
        nodediscoverstart => 'seqdiscovery',
        nodediscoverstop => 'seqdiscovery',
        nodediscoverls => 'seqdiscovery',
        nodediscoverstatus => 'seqdiscovery',
    }
}

sub findme {
    my $request = shift;
    my $callback = shift;
    my $subreq = shift;

    my @SEQdiscover = xCAT::TableUtils->get_site_attribute("__SEQDiscover");
    my @PCMdiscover = xCAT::TableUtils->get_site_attribute("__PCMDiscover");
    unless ($SEQdiscover[0]) {
        if ($PCMdiscover[0]) {
            #profile disocvery is running, then just return to make profile discovery to handle it
            return;
        }
        # update the discoverydata table to have an undefined node
        $request->{method}->[0] = 'undef';
        xCAT::DiscoveryUtils->update_discovery_data($request);
        return;
    }

    # do the sequential discovery
    xCAT::MsgUtils->message("S", "Sequential Discovery: Processing");

    # Get the parameters for the sequential discovery
    my %param;
    my @params = split (',', $SEQdiscover[0]);
    foreach (@params) {
        my ($name, $value) = split ('=', $_);
        $param{$name} = $value;
    }
    
    my $mac;
    my $ip = $request->{'_xcat_clientip'};
    if (defined $request->{nodetype} and $request->{nodetype}->[0] eq 'virtual') {
        return;
    }
    my $arptable = `/sbin/arp -n`;
    my @arpents = split /\n/,$arptable;
    foreach  (@arpents) {
        if (m/^($ip)\s+\S+\s+(\S+)\s/) {
            $mac=$2;
            last;
        }
    }
    
    unless ($mac) {
        xCAT::MsgUtils->message("S", "Discovery Error: Could not find the mac of the $ip.");
        return;
    }

    # check whether the mac could map to a node
    my $mactab = xCAT::Table->new('mac');
    unless ($mactab) {
        xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: mac.");
    }

    my $node;
    my @macs = $mactab->getAllAttribs('node', 'mac');
    # for each entry: 34:40:b5:be:db:b0!*NOIP*|34:40:b5:be:db:b0!*NOIP*
    foreach my $macnode (@macs) {
        my @macents = split ('\|', $macnode->{'mac'});
        foreach my $macent (@macents) {
            my ($usedmac) = split ('!', $macent);
            if ($usedmac =~ /$mac/i) {
                 $node = $macnode->{'node'};
                 last;
            }
        }
    }

    unless ($node) {
        # get a free node
        $node = getfreenodes($param{'noderange'});
    }

    if ($node) {
        my $skiphostip;
        my $skipbmcip;
        my @newhosts = ($node);
        # check the host ip and bmc 
        my $hosttab = xCAT::Table->new('hosts');
        unless ($hosttab) {
            xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: hosts.");
        }
        my $hostip = $hosttab->getNodeAttribs($node, ['ip']);
        if ($hostip->{'ip'}) {
            $skiphostip = 1;
        }
        
        my $ipmitab = xCAT::Table->new('ipmi');
        unless ($ipmitab) {
            xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: ipmi.");
        }
        my $ipmibmc = $ipmitab->getNodeAttribs($node, ['bmc']);
        if ($ipmibmc->{'bmc'}) {
            $skipbmcip = 1;
            unless ($ipmibmc->{'bmc'} =~ /\d+\.\d+\.\d+\.\d+/) {
                push @newhosts, $ipmibmc->{'bmc'};
            }
        }

        # set the host ip and bmc if needed
        unless ($skiphostip) {
            my $hostip = getfreeips($param{'hostiprange'});
            unless ($hostip) {
                xCAT::MsgUtils->message("S", "Discovery Error: No free host ip.");
                nodediscoverstop($callback, undef, 1);
                return;
            }
            $hosttab->setNodeAttribs($node, {ip => $hostip});
            $hosttab->commit();
        }

        my $bmcname;
        unless ($skipbmcip) {
            my $bmcip = getfreeips($param{'bmciprange'});
            unless ($bmcip) {
                xCAT::MsgUtils->message("S", "Discovery Error: No free bmc ip.");
                nodediscoverstop($callback, undef, 1);
                return;
            }
            $bmcname = $node."-bmc";
            $hosttab->setNodeAttribs($bmcname, {ip => $bmcip});
            $hosttab->commit();

            # set the bmc to the ipmi table
            $ipmitab->setNodeAttribs($node, {bmc => $bmcname});

            push @newhosts, $bmcname;
        }

        # update the host ip pair to /etc/hosts, it's necessary for discovered and makedhcp commands
        if (@newhosts) {
            my $req;
            $req->{command}=['makehosts'];
            $req->{node} = \@newhosts;
            $subreq->($req); 
        }

        # set the specific attributes from parameters
        my $updateparams;
        my %setpos;
        if (defined ($param{'rack'})) {
            $setpos{'rack'} = $param{'rack'};
        } 
        if (defined ($param{'chassis'})) {
            $setpos{'chassis'} = $param{'chassis'};
        }
        if (defined ($param{'height'})) {
            $setpos{'height'} = $param{'height'};
        }
        if (defined ($param{'unit'})) {
            $setpos{'u'} = $param{'unit'};

            if (defined ($param{'height'})) {
                $param{'unit'} += $param{'height'};
            } else {
                $param{'unit'} += 1;
            }

            $updateparams = 1;
        }
        if (keys %setpos) {
            my $postab = xCAT::Table->new('nodepos');
            unless ($postab) {
                xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: nodepos.");
            }
            $postab->setNodeAttribs($node, \%setpos);
            $postab->close();
        }
        

        if ($updateparams) {
            my $textparam;
            foreach my $name (keys %param) {
                $textparam .= "$name=$param{$name},";
            }
            $textparam =~ s/,\z//;

            # Update the discovery parameters to the site.__SEQDiscover which will be used by nodediscoverls/status/stop and findme, 
            my $sitetab = xCAT::Table->new("site");
            $sitetab->setAttribs({"key" => "__SEQDiscover"}, {"value" => "$textparam"});
            $sitetab->close();
        }

        #set the groups for the node
        my $nltab = xCAT::Table->new('nodelist');
        unless ($nltab) {
            xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: nodelist.");
        }
        if (defined ($param{'groups'})) {
            $nltab->setNodeAttribs($node, {groups=>$param{'groups'}});
            if ($bmcname) {
                $nltab->setNodeAttribs($bmcname, {groups=>$param{'groups'}.",bmc"});
            }
        } else {
            $nltab->setNodeAttribs($node, {groups=>"all"});
            if ($bmcname) {
                $nltab->setNodeAttribs($bmcname, {groups=>"all,bmc"});
            }
        }

        $request->{command}=['discovered'];
        $request->{noderange} = [$node];
        $request->{discoverymethod} = ['sequential'];
        $request->{updateswitch} = ['yes'];
        $subreq->($request); 
        %{$request}=();#Clear req structure, it's done..
        undef $mactab;
    } else {
        #
        xCAT::MsgUtils->message("S", "Discovery Error: No free node name.");
        nodediscoverstop($callback, undef, 1);
        return;
    }

    xCAT::MsgUtils->message("S", "Sequential Discovery: Done");
}

=head3 nodediscoverstart 
 Initiate the sequencial discovery process
=cut
sub nodediscoverstart {
    my $callback = shift;
    my $args = shift;

    my $usage = sub {
        my $cb = shift;
        my $msg = shift;

        my $rsp;
        if ($msg) {
            push @{$rsp->{data}}, $msg;
            xCAT::MsgUtils->message("E", $rsp, $cb, 1);
        }

        my $usageinfo = "nodediscoverstart: Start sequential nodes discovery.
Usage: 
\tnodediscoverstart noderange=<noderange> hostiprange=<imageprofile> bmciprange=<bmciprange> [groups=<groups>] [rack=<rack>] [chassis=<chassis>] [height=<height>] [unit=<unit>]
\tnodediscoverstart [-h|--help] 
\tnodediscoverstart {-v|--version}    
    ";
        $rsp = ();
        push @{$rsp->{data}}, $usageinfo;
        xCAT::MsgUtils->message("I", $rsp, $cb);
    };

    # valid attributes for deqdiscovery
    my %validargs = (
        'noderange' => 1, 
        'hostiprange' => 1,
        'bmciprange' => 1,
        'groups' => 1,
        'rack' => 1,
        'chassis' => 1,
        'height' => 1,
        'unit' => 1,
    );

    if ($args) {    
        @ARGV = @$args;
    }
    my ($help, $ver); 
    if (!GetOptions(
        'h|help' => \$help,
        'V|verbose' => \$::VERBOSE,
        'v|version' => \$ver)) {
        $usage->($callback);
        return;
    }

    if ($help) {
        $usage->($callback);
        return;
    }

    if ($ver) {
        # just return to make profile discovery to handle it
        return;
    }

    my %orgargs;
    foreach (@ARGV) {
        my ($name, $value) = split ('=', $_);
        $orgargs{$name} = $value;
    }

    # Todo: Check the noderage=has been specified which is the flag that this is for sequential discovery
    
    # Otherwise try to check the whether the networkprofile || hardwareprofile || imageprofile 
    # has been passed, if yes, return to profile discovery
    unless (defined ($orgargs{noderange}) ) {
        if (defined ($orgargs{networkprofile}) || defined($orgargs{hardwareprofile}) || defined($orgargs{imageprofile})) {
            # just return that make profile-based discovery to handle it
            return;
        } else {
            $usage->($callback, "For sequential discovery, the \'noderange\' option must be specified.");
            return;
        }
    }

    xCAT::MsgUtils->message("S", "Sequential Discovery: Start");

    my %param;    # The valid parameters
    my $textparam; # The valid parameters in 'name=value,name=value...' format

    # Check the validate of parameters
    foreach my $name (keys %orgargs) {
        unless (defined ($validargs{$name})) {
            $usage->($callback, "Invalid arguement \"$name\".");
            return;
        }
        unless (defined ($orgargs{$name})) {
            $usage->($callback, "The parameter \"$name\" need a value.");
            return;
        }

        # keep the valid parameters
        $param{$name} = $orgargs{$name};
        $textparam .= $name.'='.$param{$name}.',';
    }

    $textparam =~ s/,\z//;

    # Check the running of profile-based discovery
    my @PCMdiscover = xCAT::TableUtils->get_site_attribute("__PCMDiscover");
    if ($PCMdiscover[0]) {
        my $rsp;
        push @{$rsp->{data}}, "Sequentail Discovery cannot run together with Profile-based discovery";
        xCAT::MsgUtils->message("E", $rsp, $callback, 1);
        return;
    }

    # Check the running of sequential discovery
    my @SEQdiscover = xCAT::TableUtils->get_site_attribute("__SEQDiscover");
    if ($SEQdiscover[0]) {
        my $rsp;
        push @{$rsp->{data}}, "Sequentail Discovery is running. If you want to rerun the discovery, stop the running discovery first.";
        xCAT::MsgUtils->message("E", $rsp, $callback, 1);
        return;
    }

    # Check that the dynamic range in the dhcpd.conf has been set correctly
    # search all the network in the networks table that make sure the dynamic range for the deployment network has been set 

    # Set the discovery parameters to the site.__SEQDiscover which will be used by nodediscoverls/status/stop and findme, 
    my $sitetab = xCAT::Table->new("site");
    $sitetab->setAttribs({"key" => "__SEQDiscover"}, {"value" => "$textparam"});
    $sitetab->close();

    # Clean the entries which discovery method is 'sequential' from the discoverdata table
    my $distab = xCAT::Table->new("discoverydata");
    $distab->delEntries({method => 'sequential'});
    $distab->commit();

    # Calculate the available node name and IPs
    my @freenodes = getfreenodes($param{'noderange'}, "all");
    my @freehostips = getfreeips($param{'hostiprange'}, "all");
    my @freebmcips = getfreeips($param{'bmciprange'}, "all");

    my $rsp;
    push @{$rsp->{data}}, "Sequential node discovery started:";
    push @{$rsp->{data}}, "    Number of free node names: ".($#freenodes+1);
    if ($param{'hostiprange'}) {
        if (@freehostips) {
            push @{$rsp->{data}}, "    Number of free host ips: ".($#freehostips+1);
        } else {
            push @{$rsp->{data}}, "    No free host ips.";
        }
    }
    if ($param{'bmciprange'}) {
        if (@freebmcips) {
            push @{$rsp->{data}}, "    Number of free bmc ips: ".($#freebmcips+1);
        } else {
            push @{$rsp->{data}}, "    No free bmc ips.";
        }
    }
    xCAT::MsgUtils->message("I", $rsp, $callback);
}


=head3 nodediscoverstop 
 Stop the sequencial discovery process
=cut
sub nodediscoverstop {
    my $callback = shift;
    my $args = shift;
    my $auto = shift;

    my $usage = sub {
        my $cb = shift;
        my $msg = shift;

        my $rsp;
        if ($msg) {
            push @{$rsp->{data}}, $msg;
            xCAT::MsgUtils->message("E", $rsp, $cb, 1);
        }

        my $usageinfo = "nodediscoverstop: Stop the sequential discovery.
Usage: 
\tnodediscoverstop [-h|--help] [-v | --version]    
    ";
        $rsp = ();
        push @{$rsp->{data}}, $usageinfo;
        xCAT::MsgUtils->message("I", $rsp, $cb);
    };
    
    if ($args) {    
        @ARGV = @$args;
    }
    my ($help, $ver); 
    if (!GetOptions(
        'h|help' => \$help,
        'V|verbose' => \$::VERBOSE,
        'v|version' => \$ver)) {
        $usage->($callback);
        return;
    }

    if ($help) {
        #$usage->($callback);
        # just return to make profile discovery to handle it
        return;
    }
    if ($ver) {
        # just return to make profile discovery to handle it
        return;
    }

    # Check the running of sequential discovery
    my @SEQDiscover = xCAT::TableUtils->get_site_attribute("__SEQDiscover");
    my @PCMDiscover = xCAT::TableUtils->get_site_attribute("__PCMDiscover");
    if ($PCMDiscover[0]) {
        # return directly that profile discover will cover it
    } elsif (!$SEQDiscover[0]) {
        # Neither of profile nor sequential was running
        my $rsp;
        push @{$rsp->{data}}, "Sequential Discovery is stopped.";
        push @{$rsp->{data}}, "Profile Discovery is stopped.";
        xCAT::MsgUtils->message("E", $rsp, $callback, 1);
        return;
    }
    

    # Go thought discoverydata table and display the sequential disocvery entries
    my $distab = xCAT::Table->new('discoverydata');
    unless ($distab) {
        my $rsp;
        push @{$rsp->{data}}, "Discovery Error: Could not open table: discoverydata.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return;
    }
    my @disdata = $distab->getAllAttribsWhere("method='sequential'", 'node', 'mtm', 'serial');
    my @discoverednodes;

    foreach (@disdata) {
        push @discoverednodes, sprintf("    %-20s%-10s%-10s", $_->{'node'}, $_->{'mtm'}, substr($_->{'serial'},0,8), );
    }

    my $rsp;
    push @{$rsp->{data}}, "Discovered ".($#discoverednodes+1)." nodes.";
    if (@discoverednodes) {
        push @{$rsp->{data}}, sprintf("    %-20s%-10s%-10s", 'NODE', 'MTM', 'SERIAL');
        foreach (@discoverednodes) {
             push @{$rsp->{data}}, "$_"; 
        }
    }
    xCAT::MsgUtils->message("I", $rsp, $callback);

    if ($auto) {
        xCAT::MsgUtils->message("S", "Sequential Discovery: Auto Stopped. Run \'nodediscoverls -t seq\' to display the discovery result.");
    } else {
        xCAT::MsgUtils->message("S", "Sequential Discovery: Stop");
    }

    # Clean the entries which discovery method is 'sequential' from the discoverdata table
    unless ($auto) {
        my $distab = xCAT::Table->new("discoverydata");
        $distab->delEntries({method => 'sequential'});
        $distab->commit();
    }

    # Remove the site.__SEQDiscover
    my $sitetab = xCAT::Table->new("site");
    $sitetab->delEntries({key => '__SEQDiscover'});
    $sitetab->commit();
}

=head3 nodediscoverls 
 Display the discovered nodes
=cut
sub nodediscoverls {
    my $callback = shift;
    my $args = shift;

    my $usage = sub {
        my $cb = shift;
        my $msg = shift;

        my $rsp;
        if ($msg) {
            push @{$rsp->{data}}, $msg;
            xCAT::MsgUtils->message("E", $rsp, $cb, 1);
        }

        my $usageinfo = "nodediscoverls: list the discovered nodes.
Usage: 
\tnodediscoverls
\tnodediscoverls [-h|--help] 
\tnodediscoverls [-v | --version]    
\tnodediscoverls [-t seq|profile|switch|blade|undef|all] [-l] 
\tnodediscoverls [-u uuid] [-l]
    ";
        $rsp = ();
        push @{$rsp->{data}}, $usageinfo;
        xCAT::MsgUtils->message("I", $rsp, $cb);
    };

    if ($args) {    
        @ARGV = @$args;
    }
    my ($type, $uuid, $long, $help, $ver); 
    if (!GetOptions(
        't=s' => \$type,
        'u=s' => \$uuid,
        'l' => \$long,
        'h|help' => \$help,
        'V|verbose' => \$::VERBOSE,
        'v|version' => \$ver)) {
        $usage->($callback);
        return;
    }

    if ($help) {
        $usage->($callback);
        return;
    }
    if ($ver) {
        # just return to make profile discovery to handle it
        return;
    }

    # If the type is specified, display the corresponding type of nodes
    if ($type) {
        if ($type !~ /^(seq|profile|switch|blade|undef|all)$/) {
            $usage->($callback, "The discovery type \'$type\' is not supported.");
            return;
        }
    } elsif ($uuid) {
    } else {
        # Check the running of sequential discovery
        my @SEQDiscover = xCAT::TableUtils->get_site_attribute("__SEQDiscover");
        if  ($SEQDiscover[0]) {
            $type = "seq";
        } else {
            my @PCMDiscover = xCAT::TableUtils->get_site_attribute("__PCMDiscover");
            if ($PCMDiscover[0]) {
                #return directly if my type of discover is not running.
                 return;
            } else {
                 # no type, no seq and no profile, then just diaplay all
                 $type = "all";
            }
        }
    }

    # Go thought discoverydata table and display the disocvery entries
    my $distab = xCAT::Table->new('discoverydata');
    unless ($distab) {
        my $rsp;
        push @{$rsp->{data}}, "Discovery Error: Could not open table: discoverydata.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return;
    }
    my @disdata;
    my @disattrs;
    if ($long) {
        @disattrs = ('uuid', 'node', 'method', 'discoverytime', 'arch', 'cpucount', 'cputype', 'memory', 'mtm', 'serial', 'nicdriver', 'nicipv4', 'nichwaddr', 'nicpci', 'nicloc', 'niconboard', 'nicfirm', 'switchname', 'switchaddr', 'switchdesc', 'switchport');
    } else {
        @disattrs = ('uuid', 'node', 'method', 'mtm', 'serial');        
    }
    if ($type) {
        if ($type eq "all") {
            @disdata = $distab->getAllAttribs(@disattrs);
        } else {
            $type = "sequential" if ($type =~ /^seq/);
            @disdata = $distab->getAllAttribsWhere("method='$type'", @disattrs);
        }
    } elsif ($uuid) {
        @disdata = $distab->getAllAttribsWhere("uuid='$uuid'", @disattrs);
    }
    my $discoverednum = $#disdata + 1;
    
    my @discoverednodes;
    foreach my $ent (@disdata) {
        if ($long) {
            foreach my $attr (@disattrs) {
                if ($attr eq "uuid") {
                    push @discoverednodes, "Object uuid: $ent->{$attr}";
                } elsif (defined ($ent->{$attr})) {
                    push @discoverednodes, "    $attr=$ent->{$attr}";
                }
            }
        } else {
            $ent->{'node'} = 'undef' unless ($ent->{'node'});
            $ent->{'method'} = 'undef' unless ($ent->{'method'});
            push @discoverednodes, sprintf("  %-40s%-20s%-15s%-10s%-10s", $ent->{'uuid'}, $ent->{'node'}, $ent->{'method'}, $ent->{'mtm'}, substr($ent->{'serial'},0,8));
        }
    }

    my $rsp;
    if ($type eq "sequential") {
        push @{$rsp->{data}}, "Discovered $discoverednum node.";
    }
    if (@discoverednodes) {
        unless ($long) {
            push @{$rsp->{data}}, sprintf("  %-40s%-20s%-15s%-10s%-10s", 'UUID', 'NODE', ,'METHOD', 'MTM', 'SERIAL');
        }
        foreach (@discoverednodes) {
             push @{$rsp->{data}}, "$_"; 
        }
    }

    xCAT::MsgUtils->message("I", $rsp, $callback);
}


=head3 nodediscoverstatus 
 Display the discovery status
=cut
sub nodediscoverstatus {
    my $callback = shift;
    my $args = shift;

    my $usage = sub {
        my $cb = shift;
        my $msg = shift;

        my $rsp;
        if ($msg) {
            push @{$rsp->{data}}, $msg;
            xCAT::MsgUtils->message("E", $rsp, $cb, 1);
        }

        my $usageinfo = "nodediscoverstatus: Display the discovered status.
Usage: 
\tnodediscoverstatus [-h|--help] [-v | --version]    
    ";
        $rsp = ();
        push @{$rsp->{data}}, $usageinfo;
        xCAT::MsgUtils->message("I", $rsp, $cb);
    };
    
    if ($args) {    
        @ARGV = @$args;
    }
    my ($type, $uuid, $long, $help, $ver); 
    if (!GetOptions(
        'h|help' => \$help,
        'V|verbose' => \$::VERBOSE,
        'v|version' => \$ver)) {
        $usage->($callback);
        return;
    }

    if ($help) {
        #$usage->($callback);
        # just return to make profile discovery to handle it
        return;
    }
    if ($ver) {
        # just return to make profile discovery to handle it
        return;
    }

    # Check the running of sequential discovery
    my @SEQDiscover = xCAT::TableUtils->get_site_attribute("__SEQDiscover");
    my @PCMDiscover = xCAT::TableUtils->get_site_attribute("__PCMDiscover");
    if  ($SEQDiscover[0]) {
        my $rsp;
        push @{$rsp->{data}}, "Sequential discovery is running.";
        push @{$rsp->{data}}, "    The parameters used for discovery: ".$SEQDiscover[0];
        xCAT::MsgUtils->message("I", $rsp, $callback);
    } elsif ($PCMDiscover[0]) {
        # return directly that Profile discover to cover the output
        return;
    } else {
        my $rsp;
        push @{$rsp->{data}}, "Sequential Discovery is stopped.";
        push @{$rsp->{data}}, "Profile Discovery is stopped.";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }

}


sub process_request {
    my $request = shift;
    my $callback = shift;
    my $subreq = shift;

    my $command = $request->{command}->[0];
    my $args = $request->{arg};

    if ($command eq "findme"){
        findme($request, $callback, $subreq);
    } elsif ($command eq "nodediscoverstart") {
        nodediscoverstart($callback, $args);
    } elsif ($command eq "nodediscoverstop") {
        nodediscoverstop($callback, $args);
    } elsif ($command eq "nodediscoverls") {
        nodediscoverls($callback, $args);
    } elsif ($command eq "nodediscoverstatus") {
        nodediscoverstatus($callback, $args);
    }
}

=head3 getfreenodes 
 Get the free nodes base on the user specified noderange and defined nodes
 arg1 - the noderange
 arg2 - "all': return all the free nodes; otherwise just return one.
=cut
sub getfreenodes () {
    my $noderange = shift;
    my $all = shift;
    
    my @freenodes;

    # get all the nodes from noderange
    my @nodes = noderange($noderange, 0);
    
    # get all nodes from nodelist and mac table
    my $nltb = xCAT::Table->new('nodelist');
    unless ($nltb) {
        xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: nodelist.");
        return;
    }

    my $mactb = xCAT::Table->new('mac');
    unless ($mactb) {
        xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: mac.");
        return;
    }

    my $nlent = $nltb->getNodesAttribs(\@nodes,['groups']);
    my $macent = $mactb->getNodesAttribs(\@nodes,['mac']);
    foreach my $node (@nodes) {
        if ($nlent->{$node}->[0]) {
            unless ($macent->{$node}->[0] && $macent->{$node}->[0]->{'mac'}) {
                push @freenodes, $node;
                unless ($all) { last;}
            }
        } else {
            push @freenodes, $node;
            unless ($all) { last;}
        }
    }

    unless (@freenodes) {
        return;
    }

    if ($all ) {
        return @freenodes;
    } else {
        return $freenodes[0];
    }
}


=head3 getfreeips 
 Get the free ips base on the user specified ip range
 arg1 - the ip range. Two format are suported: 192.168.1.1-192.168.2.50; 192.168.[1-2].[10-100]
 arg2 - "all': return all the free nodes; otherwise just return one.
=cut
sub getfreeips () {
    my $iprange = shift;
    my $all = shift;

    my @freeips;

    # get all used ip from hosts table
    my $hoststb = xCAT::Table->new('hosts');
    unless ($hoststb) {
        xCAT::MsgUtils->message("S", "Discovery Error: Could not open table: hosts.");
    }

    my @hostsent = $hoststb->getAllAttribs('ip');
    my %usedips = ();
    foreach my $host (@hostsent) {
        $usedips{$host->{'ip'}} = 1;
    }

    if ($iprange =~ /(\d+\.\d+\.\d+\.\d+)-(\d+\.\d+\.\d+\.\d+)/) {
        my ($startip, $endip) = ($1, $2);
        my $startnum = xCAT::NetworkUtils->ip_to_int($startip);
        my $endnum = xCAT::NetworkUtils->ip_to_int($endip);
    
        while ($startnum <= $endnum) {
            my $ip = xCAT::NetworkUtils->int_to_ip($startnum);
            unless ($usedips{$ip}) {
                push @freeips, $ip;
                unless ($all) {last;}
            }
            $startnum++;
        }
    } else {
        # use the noderange to expand the range
        my @ips = noderange($iprange, 0);
        foreach my $ip (@ips) {
            unless ($usedips{$ip}) {
                push @freeips, $ip;
                unless ($all) {last;}
            }
        }
    }

    unless (@freeips) {
        return;
    }

    if ($all) {
        return @freeips;
    } else {
        return $freeips[0];
    }
}

1;

<#
    .SYNOPSIS
        Script for pulling stats from vCenter into Influx
    .DESCRIPTION
        This script was used in a demo during a session during
        VMworld Europe 2018.
        The script pulls performance stats for VMs and posts
        these to a InfluxDB database.
    .NOTES
        Author: Rudi Martinsen / Intility AS
        Created: 29/10-2018
        Version: 1.0.0
        Revised: 
        Changelog:
    .LINK
        https://www.rudimartinsen.com/2018/11/12/slides-from-my-vmworld-session/
    .LINK
        https://github.com/rumart/vmworld-europe-18
#>

function Get-DBTimestamp($timestamp = (get-date)){
    if($timestamp -is [system.string]){
        $timestamp = [datetime]::ParseExact($timestamp,'dd.MM.yyyy HH:mm:ss',$null)
    }
    return $([long][double]::Parse((get-date $($timestamp).ToUniversalTime() -UFormat %s)) * 1000 * 1000 * 1000)
}

$vcenterServer = "your-vcenterserver"
$vcUser = "vcenter-user"
$vcPass = "vcenter-password"

$influxDBServer = "your-influxserver"
$influxDBName = "performance"

$metrics = "cpu.ready.summation","cpu.costop.summation","cpu.latency.average","cpu.usagemhz.average","cpu.usage.average","mem.active.average","mem.usage.average","net.received.average","net.transmitted.average","disk.maxtotallatency.latest","disk.read.average","disk.write.average","net.usage.average","disk.usage.average"
$cpuRdyInt = 200
$run = 1
while($true){
    $lapstart = Get-Date
    #region Connect
        Connect-VIServer -Server $vcenterServer -User $vcUser -Password $vcPass | Out-Null
    #end region

    $vms = Get-Cluster cluster01 | Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"}
    $tbl = @()

    foreach($vm in $vms){
        
        #Build variables for vm "metadata"    
        $vid = $vm.Id
        $vname = $vm.name
        $vproc = $vm.NumCpu
        $cname = $vm.VMHost.Parent.Name
        $hname = $vm.VMHost.Name
        $vname = $vname.toUpper()

        #Get the stats
        $stats = Get-Stat -Entity $vm -Realtime -MaxSamples 2 -Stat $metrics
        
        foreach($stat in $stats){
            $instance = $stat.Instance

            if($instance -or $instance -ne ""){
                continue
            }
                
            #More metadata
            $unit = $stat.Unit
            $value = $stat.Value
            $statTimestamp = Get-DBTimestamp $stat.Timestamp

            if($unit -eq "%"){
                $unit = "perc"
            }

            #We're doing a translation from the vCenter metric names to our own measurement/table name so they can be reused for other sources
            switch ($stat.MetricId) {
                "cpu.ready.summation" { $measurement = "cpu_ready";$value = $(($Value / $cpuRdyInt)/$vproc); $unit = "perc" }
                "cpu.costop.summation" { $measurement = "cpu_costop";$value = $(($Value / $cpuRdyInt)/$vproc); $unit = "perc" }
                "cpu.latency.average" {$measurement = "cpu_latency" }
                "cpu.usagemhz.average" {$measurement = "cpu_usagemhz" }
                "cpu.usage.average" {$measurement = "cpu_usage" }
                "mem.active.average" {$measurement = "mem_usagekb" }
                "mem.usage.average" {$measurement = "mem_usage" }
                "net.received.average"  {$measurement = "net_through_receive"}
                "net.transmitted.average"  {$measurement = "net_through_transmit"}
                "net.usage.average"  {$measurement = "net_through_total"}
                "disk.maxtotallatency.latest" {$measurement = "storage_latency";if($value -ge $latThreshold){$value = 0}}
                "disk.read.average" {$measurement = "disk_through_read"}
                "disk.write.average" {$measurement = "disk_through_write"}
                "disk.usage.average" {$measurement = "disk_through_total"}
                Default { $measurement = $null }
            }

            #Add to output array
            if($measurement -ne $null){
                $tbl += "$measurement,type=vm,vm=$vname,vmid=$vid,host=$hname,cluster=$cname,unit=$unit value=$Value $stattimestamp"
            }

        }
        
    }

    Disconnect-VIServer -Server $vcenterServer -Confirm:$false

    #Post results to Influx API
    $baseUri = "http://$influxDBServer" + ":8086/"
    $postUri = $baseUri + "write?db=" + $influxDBName
    Invoke-RestMethod -Method Post -Uri $postUri -Body ($tbl -join "`n")
    
    $lapstop = Get-Date
    $lapspan = New-TimeSpan -Start $lapstart -End $lapstop
    Write-Output "Run #$run took $($lapspan.totalseconds) seconds"
    $run++
    Start-Sleep -Seconds 20
}


# Import DBA modules (functions)...
Import-Module 'AdminFunctions.psm1'

# Global config settings...
[string]$cAOGroupName = "AO Group Name (LISTENER)"
[string]$cAOListenerName = "LISTENER\INSTANCE"
[string]$cDatabaseBackupLocation = "\\servershare$\_AlwaysOnTempDir"
[string]$sSMTPServer1 = "smtp.example.com"
[string]$sToAddress1 = "admin@example.com"

# Functions en Procedures...
function fnAddDatabase2AOGroup()
{
 param (
   [string]$sAOGroupName,
   [string]$sDatabaseName,
   [string]$sPrimaryServerName,
   [string]$sSecondaryServerName,
   [string]$sDatabaseBackupLocation
 )

 # Create a timestamp...
 [string]$sDate = Get-Date -UFormat %Y%m%d%H%M

 # Concat strings to create path...
 [string]$sDatabaseBackupFile = $sDatabaseBackupLocation + "\" + $sDatabaseName + "_" + $sDate + ".bak"
 [string]$sDatabaseLogFile = $sDatabaseBackupLocation + "\" + $sDatabaseName + "_" + $sDate + ".trn"
 [string]$sAOPrimaryPath = "SQLSERVER:\SQL\" + $sPrimaryServerName + "\AvailabilityGroups\" + $sAOGroupName
 [string]$sAOSecondaryPath = "SQLSERVER:\SQL\" + $sSecondaryServerName + "\AvailabilityGroups\" + $sAOGroupName

 # Backup Data + Log on primary...
 Backup-SqlDatabase -Database $($sDatabaseName) -BackupFile $sDatabaseBackupFile -ServerInstance $($sPrimaryServerName)
 Backup-SqlDatabase -Database $($sDatabaseName) -BackupFile $sDatabaseLogFile -ServerInstance $($sPrimaryServerName) -BackupAction 'Log'

 # Restore Data + Log on secondary...
 Restore-SqlDatabase -Database $($sDatabaseName) -BackupFile $sDatabaseBackupFile -ServerInstance $($sSecondaryServerName) -NoRecovery
 Restore-SqlDatabase -Database $($sDatabaseName) -BackupFile $sDatabaseLogFile -ServerInstance $($sSecondaryServerName) -RestoreAction 'Log' -NoRecovery

 # Add Database to Availability Group...
 Add-SqlAvailabilityDatabase -Path $sAOPrimaryPath -Database $($sDatabaseName)
 Add-SqlAvailabilityDatabase -Path $sAOSecondaryPath -Database $($sDatabaseName)
}

function fnSetAllDatabases2FullRecovery()
{
 param (
         [string]$sDBServerName
       )
  
  [string]$sQuery9 = "-- Declarations and temptables... `
                      DECLARE @iNumRecs int, @iRecNum int = 1, @vCommand nvarchar(max) `
                      CREATE TABLE #tCommands (ID int IDENTITY(1,1), Command nvarchar(max)) `
                      -- Insert Commands into temptable... `
                      INSERT INTO #tCommands (Command) `
                      SELECT N'ALTER DATABASE [' + name + '] SET RECOVERY FULL WITH NO_WAIT' `
                      FROM [master].[sys].[databases] `
                      WHERE recovery_model_desc = 'SIMPLE' AND name NOT in ('master', 'msdb', 'tempdb') `
                      -- Execute commands from temptable... `
                      SELECT @iNumRecs = COUNT(*) FROM #tCommands `
                      WHILE @iRecNum <= @iNumRecs `
                      BEGIN `
                        SELECT @vCommand = Command FROM #tCommands `
                        WHERE ID = @iRecNum `
                        -- Execute command and increase record number... `
                        -- EXECUTE(@vCommand) --Alternative, Not preferred... `
                        EXECUTE sys.sp_executesql @stmt = @vCommand `
                        SET @iRecNum += 1 `
                      END `
                      -- Cleanup... ` 
                      DROP TABLE #tCommands"
  fnSQLCmd -sInstance $($sDBServerName) -sQuery $sQuery9 -sDatabase "master" 
}


### Start main script... ###

# First we set all databases to full recovery...
fnSetAllDatabases2FullRecovery -sDBServerName $($cAOListenerName)

# Retrieve AlwaysOn information from listener...
[string]$sQuery0 = "-- Retrieve AllwaysOn information and status... `
                    SELECT nim.ag_name, arcs.replica_id, arcs.replica_server_name, arcs.join_state, `
                    arcs.join_state_desc, ars.is_local, ars.role, ars.role_desc, `
                    ars.operational_state, ars.operational_state_desc, ars.recovery_health, `
                    ars.recovery_health_desc, ars.synchronization_health, ars.synchronization_health_desc `
                    FROM [master].[sys].dm_hadr_availability_replica_states ars `
                    INNER JOIN [master].[sys].dm_hadr_availability_replica_cluster_states arcs ON ars.replica_id = arcs.replica_id `
                    INNER JOIN [master].[sys].dm_hadr_name_id_map nim ON arcs.group_id = nim.ag_id"
if ($oResult0) { Remove-Variable -name oResult0 }
# Force in object so we can always count...
[Object[]]($oResult0) = fnSQLCmd -sInstance $($cAOListenerName) -sQuery $sQuery0 -sDatabase "master"

# Retrieve primary and secondary nodes for group...
foreach($rows0 in $oResult0) {
  if (($rows0["ag_name"] -eq $($cAOGroupName)) -and ($rows0["role"] -eq "1")) { 
    [string]$cPrimaryServerName = $rows0["replica_server_name"] 
    [string]$cPrimaryReplicaID = $rows0["replica_id"]
  }
  if (($rows0["ag_name"] -eq $($cAOGroupName)) -and ($rows0["role"] -eq "2")) { [string]$cSecondaryServerName = $rows0["replica_server_name"] }
}

# Retrieve database names...
[string]$sQuery1 = "-- Return all unreplicated databases without `
                    SELECT name FROM [master].[sys].[databases] `
                    WHERE name NOT IN ('master','tempdb','model','msdb','SSISDB') `
                    AND replica_id IS NULL"
if ($oResult1) { Remove-Variable -name oResult1 }
[Object[]]($oResult1) = fnSQLCmd -sInstance $($cAOListenerName) -sQuery $sQuery1 -sDatabase "master" 

# Process the rows returned...
foreach($rows1 in $oResult1) {
  if (($cPrimaryServerName) -and ($cPrimaryServerName)) {
  fnAddDatabase2AOGroup -sAOGroupName $cAOGroupName -sDatabaseName ($rows1["name"]) -sPrimaryServerName $cPrimaryServerName -sSecondaryServerName $cSecondaryServerName -sDatabaseBackupLocation $cDatabaseBackupLocation
  } 
}

# Check database replication state...
Start-Sleep -m 10000
[string]$sQuery2 = "-- Check database replication state... `
                    SELECT db.name, db.replica_id, synchronization_state, synchronization_health_desc `
                    FROM [master].[sys].[databases] db `
                    LEFT OUTER JOIN [master].[sys].[dm_hadr_database_replica_states] dbrs ON db.database_id = dbrs.database_id `
                    WHERE name NOT IN ('master','tempdb','model','msdb', 'SSISDB') `
                    AND (db.replica_id IS NULL OR synchronization_state <> 2)"
# Force in object so we can always count...
if ($oResult2) { Remove-Variable -name oResult2 }
[Object[]]($oResult2) = fnSQLCmd -sInstance $($cAOListenerName) -sQuery $sQuery2 -sDatabase "master"

# Send report if sync state <> 2 or database not replicated... 
if ($oResult2.Count -gt 0) {
  # Build HTML body...
  [string]$sHTML_Body1 = "<html><head><style>th {background-color: grey;} td {background-color: lightblue;}</style><title></title></head><body>"
  [string]$sHTML_Body1 += $oResult2 | ConvertTo-Html name, replica_id, synchronization_health_desc -Fragment
  [string]$sHTML_Body1 += "</body></html>"
 
  # Build TEXT body...
  [string]$sResult2 = $oResult2 | Out-String
  [string]$sTEXT_Body1 = $sResult2

  # Send messages...
  [string]$sSubject1 = ($cAOListenerName.Replace("\", "_")) + ":Database(s) not replicated..."
  fnSendMail -sSMTPSrvrName $sSMTPServer1 -sFrom (fnGetFQDN -swIsEmail) -sTo $sToAddress1 -sSubject $sSubject1 -sBody $sHTML_Body1 -swIsBodyHTML

  # Write to Eventlog...
  $sTEXT_Body1 = $sSubject1 + $sTEXT_Body1
  fnWriteEventLog -sNode ($cAOListenerName.Replace("\", "_")) -sMessage $sTEXT_Body1
}
#!/bin/sh

#--exit 007
## tmp hold till first run is completed ++

## run rclone sync to google share drive on a list of directories
## this version use  tar | rclone cat ...

## script placed in /etc/cron.monthly/rclone_tar.sh
## this version now is ALTERNATING between EVEN and ODD months
## but is NOT doing rotation in the sense move renaming old backup or removing them if they are more than 7 days old.

## Tin 2020.12.03, add:
## check for rcat status, if get error cuz hit g-drive daily limit, sleep and wait and loop
## Tin 2020.12.23, add:
## only retry on exit 403 which is rate exceeded, move on for other exit code



##LOCAL_BACKUP_LIST="/home"       # beppic-filer
##LOCAL_BACKUP_LIST="/home /eda"    # beppic-filer
#LOCAL_BACKUP_LIST="/global/oldhome /eda"    # beppic-filer
#++LOCAL_BACKUP_LIST="/home /global/oldhome /eda"    # beppic-filer

##LOCAL_BACKUP_LIST="/opt/gitlab/backups"       # greyhound

# LOCAL_BACKUP_LIST="/dbbackup/mysql_backups"  # beagle - rclone in cron.daily
# /etc /srv are annoying as they create too many little files, so left that to the 7-day rotation script
#++LOCAL_BACKUP_LIST="/global/home/users /clusterfs/gretadev/data /opt"  # beagle tar

###LOCAL_BACKUP_LIST="/etc /global/home "  # hima, these should be in crypt-hpcs-backup
#++LOCAL_BACKUP_LIST="/etc /global/home /global/data/buddha /global/data/ccosemis /global/data/ccosemis-off /global/data/goddess /global/data/gpanda /global/data/home-gpanda /global/data/mariah /global/data/mariahdata /global/data/seasonal /global/data/seasonal2 /global/data/transportation /global/data/usrbackup"  # hima
LOCAL_BACKUP_LIST="/global/data/gpanda /global/data/home-gpanda /global/data/mariah /global/data/mariahdata /global/data/seasonal /global/data/seasonal2 /global/data/transportation /global/data/usrbackup     /etc /global/home /global/data/buddha /global/data/ccosemis /global/data/ccosemis-off /global/data/goddess"  # hima (alt ordering)

##  a tar will be created, so it will be big.  but many many of those /global/data better off not encrypted
## the list is from /etc/fstab

# next would benefits from having versions
#LOCAL_BACKUP_LIST="/dbbackup/mysql_backups /etc /home /clusterfs/gretadev/data"
#

##MAILTO="hpcs-logs@lbl.gov"
MAILTO="tin@lbl.gov"

#LogPrefix="/var/log/rclone_sync_log"
LogPrefix="/var/log/rclone_tar_log"


PROG=rclone_tar
PidFile="/var/lock/$PROG"


REMOTE_NAME_NoCrypt="hpcs-backup"   # for logs only
REMOTE_NAME="hpcs-backup"          # for machines not wanting encryption, eg hima
#++REMOTE_NAME="crypt-hpcs-backup"
ROOT_FOLDER="/"						# config file store in "/rclone-crypt" folder

TRANSFER_COUNT=16
CHECKER_COUNT=16
RCLONE="/bin/rclone -v --transfers=$TRANSFER_COUNT --checkers=$CHECKER_COUNT"
##RCLONE="/bin/rclone -v"
##RCLONE="/bin/rclone --syslog"
SUM_EXIT_CODE=0
CUR_DATE=`date +%Y%m%d`
LOGFILE=$LogPrefix.$CUR_DATE.txt
Month=`date +%m`
#### path Infix for Even or Odd depending on month
if [[ $(( $Month % 2 )) -eq 0 ]]; then
	Mod="Even"
else
	Mod="Odd"
fi

#-- TMP manual modifier  ++ CHANGE_ME ++
Mod=2020dec23

# tar this way seems to exclude .snapshot already, but better be safe.
#TarExclude="--exclude='.snapshot'"
TarExclude="--exclude='.snapshot' --exclude='.cache' --exclude 'SCRATCH'"

MaxTry=60 # 57 tries 50 min apart will be 2 days
RetryWait=3060 # 51 minutes

echo "====================  rclone_tar - $CUR_DATE ============"

run_rclone_push() {
	for LOCAL_BACKUP in $LOCAL_BACKUP_LIST; do
		BACKUPNAME=$( echo $LOCAL_BACKUP | sed 's^/^_^g' )
		echo "-------- Processing $LOCAL_BACKUP at $(date) --------"
		#--$RCLONE mkdir $REMOTE_NAME:$ROOT_FOLDER/$LOCAL_BACKUP ## > /dev/null 2>&1
		# eg  crypt-hpcs-backup://global/oldhome 
		$RCLONE mkdir $REMOTE_NAME:$ROOT_FOLDER/$Mod/$BACKUPNAME ## > /dev/null 2>&1
		# eg   crypt-hpcs-backup://Even/global_oldhome 
		# NOT  crypt-hpcs-backup://global_oldhome/Even # cuz then maybe lost among a dir with many files

		#$RCLONE --transfers=$TRANSFER_COUNT --checkers=$CHECKER_COUNT sync $LOCAL_BACKUP  ${REMOTE_NAME}:${ROOT_FOLDER}/${LOCAL_BACKUP}
		# create loop for each SUB_ITEM_LIST
		for SUB_ITEM_ENTRY in $( ls -1 $LOCAL_BACKUP ); do
			#xx SUB_ITEM_ENTRY=tin
			echo "-------- Processing $Mod/$BACKUPNAME/$SUB_ITEM_ENTRY at $(date) --------"
			EXIT_CODE=1
			TRIAL=1
			while [[ $EXIT_CODE -ne 0 && $TRIAL -lt $MaxTry ]]; do
				echo "running... cd $LOCAL_BACKUP; tar cfz - $TarExclude -- $SUB_ITEM_ENTRY | $RCLONE rcat ${REMOTE_NAME}:${ROOT_FOLDER}/$Mod/${BACKUPNAME}/${SUB_ITEM_ENTRY}.tgz"
				cd $LOCAL_BACKUP; tar cfz - $TarExclude -- $SUB_ITEM_ENTRY | $RCLONE rcat ${REMOTE_NAME}:${ROOT_FOLDER}/$Mod/${BACKUPNAME}/${SUB_ITEM_ENTRY}.tgz
				EXIT_CODE=$?
				if [[ EXIT_CODE -eq 403 ]]; then
					# 403 is rate limit exceeded, so worth retrying
					echo "Non 0 EXIT_CODE ($EXIT_CODE), sleeping $RetryWait before retry -- $(date)"
					sleep $RetryWait
					TRIAL=$((TRIAL + 1))
				elif [[ EXIT_CODE -ne 0 ]]; then
					echo "Non 0 EXIT_CODE ($EXIT_CODE), but not retrying -- $(date)"
					TRIAL=${MaxTry} # set to last trial so that it would exit while loop and onto next item
				fi
			done

			echo "rclone of $Mod/$BACKUPNAME/$SUB_ITEM_ENTRY had exit code of $EXIT_CODE"
			SUM_EXIT_CODE=$( expr $EXIT_CODE + $SUM_EXIT_CODE )
		done
	done
	if [[ 0 -ne $SUM_EXIT_CODE  ]]; then
		echo "SUM_EXIT_CODE is $SUM_EXIT_CODE" | mail -s "WARN: $HOSTNAME : /etc/cron.../rclone_tar.sh had non zero exit code, please check" "$MAILTO"
	fi
}


########################################
########################################
#### "main"
########################################
########################################

if [[ -f $PidFile ]] ; then
	echo "PID file $PidFile exist, exiting"
	exit 1
else
	touch $PidFile
	date >> $PidFile
	#run_rclone_push 2>&1 | tee -a $LOGFILE | mail -s "$HOSTNAME - rclone_tar/rcat monthly" "$MAILTO"
	run_rclone_push 2>&1 | tee -a $LOGFILE
	RcloneExit=$?
	echo "RcloneExit is $RcloneExit" >> $PidFile
	date >> $PidFile
	echo "====================" >> $PidFile
	if [[ $RcloneExit -ne 0 ]]; then
		# only mail if non exit code
		cat $PidFile $LOGFILE | mail -s "$HOSTNAME - nonzero WARN: $RcloneExit - rclone_tar/rcat monthly" "$MAILTO" 
	fi
	$RCLONE mkdir ${REMOTE_NAME_NoCrypt}:/log
	$RCLONE copy $LOGFILE ${REMOTE_NAME_NoCrypt}:/log
	$RCLONE copy $PidFile ${REMOTE_NAME_NoCrypt}:/log  # PidFile is overwritten every time, it is okay, don't want to keep too many
	# rclone encounter // will create a "New Folder" in google drive

	rm $PidFile
	#rm $LOGFILE
fi


exit


##
## rclone exit code
## 

## these can sleep and retry:
##2020/12/14 20:21:17 Failed to rcat: googleapi: Error 403: User rate limit exceeded., userRateLimitExceeded



## these need to move on instead of keep retrying:
## running... cd /global/data/gpanda; tar cfz - --exclude='.snapshot' --exclude='.cache' --exclude 'SCRATCH' -- ljin | /bin/rclone -v --transfers=16 --checkers=16 rcat hpcs-backup://2020dec11/_global_data_gpanda/ljin.tgz
## 2020/12/22 18:29:19 Failed to rcat: googleapi: Error 413: Request Too Large, uploadTooLarge




## vim: tabstop=4 paste background=dark noexpandtab


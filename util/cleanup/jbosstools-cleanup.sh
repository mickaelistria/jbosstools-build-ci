#!/bin/sh
# This script is run here: http://hudson.qa.jboss.com/hudson/job/jbosstools-cleanup/configure
# And archived here: http://anonsvn.jboss.org/repos/jbosstools/trunk/build/util/cleanup/jbosstools-cleanup.sh
# --------------------------------------------------------------------------------
# clean JBT builds from sftp://tools@filemgmt.jboss.org/downloads_htdocs/tools/builds/nightly

now=$(date +%s)
log=/tmp/${0##*/}.log.`date +%Y%m%d-%H%M`.txt

echo "Logfile: $log" | tee -a $log
echo "" | tee -a $log

#commandline options so we can call this by itself using 
#	`jbosstools-cleanup.sh -k 1 -a 2` 
# or call it from within publish.sh using 
# 	`jbosstools-cleanup.sh -k 5 -a 5`

#defauls
numbuildstokeep=1000 # keep X builds per branch
threshholdwhendelete=365 # purge builds more than X days old
dirsToScan="builds/nightly/core builds/nightly/coretests builds/nightly/soa-tooling builds/nightly/soatests builds/nightly/webtools"
delete=1 # if 1, files will be deleted. if 0, files will be listed for delete but not actually removed

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 [-k num-builds-to-keep] [-a num-days-at-which-to-delete] [-d dirs-to-scan]"
	echo "Example (Jenkins): $0 -k 1 -a 2"
	echo "Example (publish.sh): $0 -k 5 -a 5"
	echo "Example: $0 -d 'updates/development/indigo/soa-tooling/modeshape/' --regen-metadata-only" 
	exit 1;
fi

# read commandline args
while [[ "$#" -gt 0 ]]; do
	case $1 in
		'-k'|'--keep') numbuildstokeep="$2"; shift 1;;
		'-a'|'--age-to-delete') threshholdwhendelete="$2"; shift 1;;
		'-d'|'--dirs-to-scan') dirsToScan="$2"; shift 1;;
		'-M'|'--regen-metadata-only') delete=0; shift 0;;
	esac
	shift 1
done

getSubDirs () 
{
	getSubDirsReturn="";
	tab="";
	if [[ $1 ]]; then dir="$1"; else dir="/downloads_htdocs/tools/builds/nightly/"; fi
	if [[ $2 ]] && [[ $2 -gt 0 ]]; then
		lev=$2
		while [[ $lev -gt 0 ]]; do  
			tab=$tab"> ";
			(( lev-- ));
		done
	fi
	echo "${tab}Check $dir..." | tee -a $log
	tmp=`mktemp`
	echo "ls $dir" > $tmp
	dirs=$(sftp -b $tmp tools@filemgmt.jboss.org 2>/dev/null)
	i=0
	for c in $dirs; do
		if [[ $i -gt 2 ]] && [[ $c != "sftp>" ]] && [[ ${c##*.} != "" ]]; then # valid dir
			getSubDirsReturn=$getSubDirsReturn" "$c
		fi
		(( i++ ))
	done
	rm -f $tmp
}

# Check for $type builds more than $threshhold days old; keep minimum $numkeep builds per branch
clean () 
{
	type=$1 # builds/nightly or updates/development/juno/soa-tooling, etc.
	numkeep=$2 # number of builds to keep per branch
	threshhold=$3 # purge builds more than $threshhold days old
	echo "Check for $type builds more than $threshhold days old; keep minimum $numkeep builds per branch" | tee -a $log 

	getSubDirs /downloads_htdocs/tools/$type/ 0
	subdirs=$getSubDirsReturn
	for sd in $subdirs; do
		getSubDirs $sd 1
		subsubdirs=$getSubDirsReturn
		#echo $subsubdirs
		tmp=`mktemp`
		for ssd in $subsubdirs; do
			if [[ ${ssd##$sd/201*} == "" ]]; then # a build dir
				buildid=${ssd##*/};  
				echo $buildid >> $tmp
			fi
		done
		newest=$(cat $tmp | sort -r | head -$numkeep) # keep these
		all=$(cat $tmp | sort -r) # check these
		rm -f $tmp
		for dd in $all; do
			keep=0;
			# sec=$(date -d "$(echo $dd | perl -pe "s/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})/\1-\2-\3\ \4:\5/")" +%s) # convert buildID (folder) to timestamp, then to # seconds since epoch ## OLD FOLDER FORMAT
			sec=$(date -d "$(echo $dd | perl -pe "s/(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})-H(\d+)/\1-\2-\3\ \4:\5:\6/")" +%s) # convert buildID (folder) to timestamp, then to # seconds since epoch ## NEW FOLDER FORMAT
			(( day = now - sec )) 
			(( day = day / 3600 / 24 ))
			for n in $newest; do
				if [[ $dd == $n ]] || [[ $day -le $threshhold ]]; then
					keep=1
				fi
			done
			if [[ $keep -eq 0 ]]; then
				echo -n "- $sd/$dd (${day}d)... " | tee -a $log
				if [[ $delete -eq 1 ]]; then
					if [[ $USER == "hudson" ]]; then
						# can't delete the dir, but can at least purge its contents
						rm -fr /tmp/$dd; mkdir /tmp/$dd; pushd /tmp/$dd >/dev/null
						rsync --rsh=ssh --protocol=28 -r --delete . tools@filemgmt.jboss.org:$sd/$dd 2>&1 | tee -a $log
						echo -e "rmdir $dd" | sftp tools@filemgmt.jboss.org:$sd/
						popd >/dev/null; rm -fr /tmp/$dd
					fi
					echo "" | tee -a $log
				else
					echo " SKIPPED."
				fi
			else
				echo "+ $sd/$dd (${day}d)" | tee -a $log
			fi
		done

		# generate metadata in the nightly/core/trunk/ folder to composite the remaining sites into one
		getSubDirs $sd 1; #return #getSubDirsReturn
		subsubdirs=$getSubDirsReturn
		#echo $subsubdirs
		tmp=`mktemp`
		for ssd in $subsubdirs; do
			if [[ ${ssd##$sd/201*} == "" ]]; then # a build dir
				buildid=${ssd##*/};  
				echo $buildid >> $tmp
			fi
		done
		all=$(cat $tmp | sort -r) # check these
		rm -f $tmp

		getListSize $all; #return $getListSizeReturn
		if [[ $getListSizeReturn -gt 0 ]]; then
			echo "Generate metadata for ${getListSizeReturn} subdir(s) in $sd/" | tee -a $log	
			mkdir -p /tmp/cleanup-fresh-metadata/
			regenCompositeMetadata "$all" "$getListSizeReturn" "org.eclipse.equinox.internal.p2.metadata.repository.CompositeMetadataRepository" "/tmp/cleanup-fresh-metadata/compositeContent.xml"
			regenCompositeMetadata "$all" "$getListSizeReturn" "org.eclipse.equinox.internal.p2.artifact.repository.CompositeArtifactRepository" "/tmp/cleanup-fresh-metadata/compositeArtifacts.xml"
			rsync --rsh=ssh --protocol=28 -q /tmp/cleanup-fresh-metadata/composite*.xml tools@filemgmt.jboss.org:$sd/
			rm -fr /tmp/cleanup-fresh-metadata/
		else
			echo "No subdirs found in $sd/" | tee -a $log	
			# TODO delete composite*.xml from $sd/ folder if there are no subdirs present
		fi
	done
	echo "" | tee -a $log	
}

# determine the number of items in a space-separated list
getListSize ()
{
	list=$1
	getListSizeReturn=0;
	for item in $list; do
		let getListSizeReturn=getListSizeReturn+1;
	done
}

#regen metadata for remaining subdirs in this folder
regenCompositeMetadata ()
{
	subsubdirs=$1
	countChildren=$2
	fileType=$3
	fileName=$4
	now=$(date +%s000)
	
	echo "<?xml version='1.0' encoding='UTF-8'?><?compositeArtifactRepository version='1.0.0'?>
<repository name='JBoss Tools Builds - ${type}' type='${fileType}' version='1.0.0'>
<properties size='2'><property name='p2.timestamp' value='${now}'/><property name='p2.compressed' value='true'/></properties>
<children size='${countChildren}'>" > ${fileName}
	for ssd in $subsubdirs; do
		echo "<child location='${ssd}/all/repo/'/>" >> ${fileName}
	done
	echo "</children>
</repository>
" >> ${fileName}
}

# now that we have all the methods and vars defined, let's do some cleaning!
for dir in $dirsToScan; do
	clean $dir $numbuildstokeep $threshholdwhendelete
done

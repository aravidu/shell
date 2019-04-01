#!/bin/bash

# cleanup-folder client-id
# takes cleanup-folder and client-id as input parameters.
# usage
if [[ -z $1 ]]; then
   echo "usage: ./run_impact_query.sh [cleanup-folder|cleanup-folder/sql.query] [client-id]"
   exit 1;
fi

# define variables
CLIENT_ID=$2
DATE=`date +%Y%m%d`

if [[ -d $1 ]]; then
   echo "this is a directory.."
   CLEANUP_DIR=$1
else
   echo "this is not a dir.."
   # so.. parse this value (assumes that user sent either a file or path to file)
   if [[ $1 = *"/"* ]]; then
      echo "It's a path, so parse it.."
      CLEANUP_DIR=`echo $1 | awk -F"/" '{print $1}'`
      IMPACT_QRY=`echo $1 | awk -F"/" '{print $2}'`
   fi
fi

RELEASE_NUM=`echo $CLEANUP_DIR | cut -d"_" -f2`

echo "cleanup folder: "$CLEANUP_DIR
echo "release number: "$RELEASE_NUM
echo "impact query: "$IMPACT_QRY
echo "client id: "$CLIENT_ID


# reads prod configs from a file called impact.config. its a key/value pair that has
# batch server name & default script folder path and copies these .sql to batch servers'
# cleanup folder (which is the same across clients)
# impact.config will have entries like this: vgprod=vgprod1-batch2;maxit/VGI_EXADATA/Loading
BATCH_SERVER=`grep $CLIENT_ID= impact.config | cut -d'=' -f2 | cut -d';' -f1`
SERVER_PATH=`grep $CLIENT_ID= impact.config | cut -d'=' -f2 | cut -d';' -f2`
echo "batch server: "$BATCH_SERVER
echo "batch server path: "$SERVER_PATH


# check if batch server cleanup folder exists
ssh drone@$BATCH_SERVER "
if [[ -d ~/maxit/$CLEANUP_DIR ]]; then
   echo "cleanup folder on server exists..";
else
   mkdir ~/maxit/$CLEANUP_DIR;
fi"

# takes whatever .sql are in cleanup-folder and copies to server
if [[ -z $IMPACT_QRY ]]; then
   echo "check for insert/update qrys before copy.."
   for i in $(ls $CLEANUP_DIR/*.sql); do
      #echo "what is i: "$i
      if [[ `grep -i "insert\|update" $i|wc -l` != "0" ]]; then
         echo "has insert,update.. so, don't copy to server; exiting.."
      else
         echo "$i not an insert/update qry so, copying to server.."
         #scp -p $CLEANUP_DIR/*.sql drone@$BATCH_SERVER:~/maxit/$CLEANUP_DIR/
         scp -p $i drone@$BATCH_SERVER:~/maxit/$CLEANUP_DIR/ >/dev/null
      fi
   done
else
   if [[ `grep -i "insert\|update" $CLEANUP_DIR/$IMPACT_QRY|wc -l` != "0" ]]; then
      echo "has insert,update.. so, don't copy to server; exiting.."
      exit 1;
   else
      echo "its not an insert/update qry so, can copy to server.."
      scp -p $CLEANUP_DIR/$IMPACT_QRY drone@$BATCH_SERVER:~/maxit/$CLEANUP_DIR/
   fi
fi


echo ""
echo "done copying.. "


# checks whether tp is running on client batch server.
# if tp is running, exit
# if tp is not running, runs .sql one after another.
if [[ -z $IMPACT_QRY ]]; then
   echo ""
   echo "running each sql to find impact.."
   echo ""
   ssh drone@$BATCH_SERVER "
   cd $SERVER_PATH;
   for i in \$(ls ~/maxit/$CLEANUP_DIR/*.sql); do
      echo \"query running is: \"\$i;
      ./sql_report.sh \$i > \$i.txt 2>&1 & echo \$! > \$i.pid;
      val=\`cat \$i.pid\`;
      echo \$val > ~/maxit/$CLEANUP_DIR/running.prcs
      ps -p \`cat ~/maxit/$CLEANUP_DIR/running.prcs\` | wc -l > ~/maxit/$CLEANUP_DIR/count.txt
      prcs_running=\`cat ~/maxit/$CLEANUP_DIR/count.txt\`;
      #echo \$prcs_running
      while [ 1 -ne \$prcs_running ]; do
         ps -p \`cat ~/maxit/$CLEANUP_DIR/running.prcs\` | wc -l > ~/maxit/$CLEANUP_DIR/count.txt
         prcs_running=\`cat ~/maxit/$CLEANUP_DIR/count.txt\`;
         #echo \$prcs_running
         #echo \"running \$i impact query..\"
      done;
   done
   rm -rf ~/maxit/$CLEANUP_DIR/count.txt
   cd ~/maxit/$CLEANUP_DIR/;
   rm -rf indv-impact.txt running.prcs *.pid
   for i in \$(ls *.sql.txt); do
      wc -l \$i >> indv-impact.txt
      val1=\$val1\" \"\`echo \$i\`;
   done;

   #cat indv-impact.txt
   #rm -rf indv-impact.txt
   cat \$val1 |sort -u > master-$CLIENT_ID-$RELEASE_NUM-$DATE.txt"
   #wc -l master-$CLIENT_ID-$RELEASE_NUM-$DATE.txt"

   echo ""
   echo "done getting impacts.."
   echo ""
else
   echo "run only the input query: "$IMPACT_QRY
   ssh drone@$BATCH_SERVER "
   cd $SERVER_PATH;
   qry=\`echo ~/maxit/$CLEANUP_DIR/$IMPACT_QRY\`
   echo \"qry is: \"\$qry
   ./sql_report.sh \$qry > \$qry.txt 2>&1 & echo \$! > \$qry.pid;
   val=\`cat \$qry.pid\`;
   ps -p \`cat \$qry.pid\` | wc -l > ~/maxit/$CLEANUP_DIR/count1.txt
   prcs_running=\`cat ~/maxit/$CLEANUP_DIR/count1.txt\`;
   echo \$prcs_running
   while [ 1 -ne \$prcs_running ]; do
      ps -p \`cat \$qry.pid\` | wc -l > ~/maxit/$CLEANUP_DIR/count1.txt
      prcs_running=\`cat ~/maxit/$CLEANUP_DIR/count1.txt\`;
      echo \$prcs_running
      echo \"running $IMPACT_QRY impact query..\"
   done;
   rm -rf ~/maxit/$CLEANUP_DIR/count1.txt ~/maxit/$CLEANUP_DIR/*.pid
   cd ~/maxit/$CLEANUP_DIR/;
   for i in \$(ls *.sql.txt); do
      wc -l \$i >> indv-impact.txt
      val1=\$val1\" \"\`echo \$i\`;
   done;
   cat indv-impact.txt
   cat \$val1 |sort -u >> master-$CLIENT_ID-$RELEASE_NUM-$DATE.txt
   wc -l master-$CLIENT_ID-$RELEASE_NUM-$DATE.txt"
fi


echo ""
echo "back in releasemaxit.. copying impacts here.."
echo ""
# done gathering impacts, now copy to releasemaxit
# if folder cleanup_????/impacts/client folder exists, delete it; one fresh copy is enough
if [[ -d ./$CLEANUP_DIR/impacts/$CLIENT_ID  ]]; then
   echo "impact folder exists, delete it.."
   rm -rf ./$CLEANUP_DIR/impacts/$CLIENT_ID/
fi

echo "create folder.."
mkdir -p ./$CLEANUP_DIR/impacts/$CLIENT_ID/

# now copy all of the client impacts to client impact folder
scp -p drone@$BATCH_SERVER:~/maxit/$CLEANUP_DIR/*.txt ./$CLEANUP_DIR/impacts/$CLIENT_ID/

# just display impact counts for ease..
for i in $(ls ./$CLEANUP_DIR/impacts/$CLIENT_ID/*.sql.txt); do
   wc -l $i >> indv-impact.txt
   val1=$val1" "`echo $i`;
done;

echo ""
echo "displaying impact counts.."
echo ""
cat indv-impact.txt
rm -rf indv-impact.txt
wc -l ./$CLEANUP_DIR/impacts/$CLIENT_ID/master-$CLIENT_ID-$RELEASE_NUM-$DATE.txt



# end of script

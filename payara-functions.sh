#!/bin/bash

# set variables, if not present
TMP_DIR="/tmp"
PAYARA_VERSION="5.2020.4";
PAYARA_DIR="$TMP_DIR/payara-micro"
PAYARA_VERSION_DIR="$PAYARA_DIR/$PAYARA_VERSION"
PAYARA_JAR="$PAYARA_VERSION_DIR/payara-micro-$PAYARA_VERSION.jar"
PAYARA_WARMED_UP_CLASSES_LST="payara-classes.lst"
PAYARA_WARMED_UP_CLASSES_JSA="payara-classes.jsa"
PAYARA_WARMED_UP_LAUNCHER="launch-micro.jar"

APP_HTTP_PORT=8080
APP_DEBUG_PORT=5005

payara_download() {
  local prefix="PAYARA::DOWNLOAD"
  # check for latests payara version (https://repo1.maven.org/maven2/fish/payara/extras/payara-micro/maven-metadata.xml metadata/versioning/latest or release?) and inform if differ from $PAYARA_VERSION
  if [ ! -f "$PAYARA_JAR" ]; then
    print_info "$prefix - Payara $PAYARA_VERSION not available. Starting download..."
    mkdir -p "$PAYARA_VERSION_DIR"
    curl "https://repo1.maven.org/maven2/fish/payara/extras/payara-micro/$PAYARA_VERSION/payara-micro-$PAYARA_VERSION.jar" -o "$PAYARA_JAR"
  else 
    print_info "$prefix - Payara $PAYARA_VERSION available. No download needed."
  fi
}

payara_run() {
  print_info "PAYARA::RUN - Starting payara $PAYARA_VERSION."
  local app_name=$1
  local http_port=$2
  local debug_port=$3
  local app_path=$4
  local paraya_options=$5
  if [ ! "$#" -eq 5 ]; then
    echo "payara_run needs 5 parameter: app_name http_port debug_port app_path payara_options"
    echo "example: payara_run app 8080 5005 \"$HOME/Projects/app/target/app\" \"--prebootcommandfile $HOME/Projects/app/target/app/pre-boot-commands.txt\""
    return 1
  fi

  local payara_root="$PAYARA_VERSION_DIR/$app_name/payara-root"
  mkdir -p "$payara_root"
  payara_download
  payara_warm_up $payara_root
  # ensure that a minimal web-app is present with a empty WEB-INF
  mkdir -p "$app_path/WEB-INF"
  java\
    -XX:-UsePerfData\
	  -XX:+TieredCompilation\
	  -XX:TieredStopAtLevel=1\
	  -XX:+UseParallelGC\
	  -XX:ActiveProcessorCount=$(get_cpu_cores)\
	  -XX:CICompilerCount=$(get_cpu_cores)\
	  -Xshare:on\
	  -XX:SharedArchiveFile="$payara_root/$PAYARA_WARMED_UP_CLASSES_JSA"\
	  -Xlog:class+path=info\
	  -Xverify:none\
	  -Xdebug\
	  -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address="$debug_port"\
	  -Dorg.glassfish.deployment.trace\
	  -jar "$payara_root/$PAYARA_WARMED_UP_LAUNCHER"\
	  --deploy "$app_path"\
	  --nocluster\
	  --contextroot "/"\
	  --port "$http_port" $paraya_options
}

app_redeploy() {
  print_info "APP::REDEPLOY"
  local app_path=$1
  echo "" > "$app_path/.reload"
  # check if deployed
  # update .reload
}

payara_clean() {
  local app_name=$1
  print_info "PAYARA::CLEAN - Cleaning up warmed up payara and checkpoint for app $app_name."
  sudo rm -fvr "$PAYARA_VERSION_DIR/$app_name"
}

checkpoint_create() {
  local prefix="CHECKPOINT::CREATE"
  local app_name=$1
  local http_port=$2
  local checkpoint_dir="$PAYARA_VERSION_DIR/$app_name/checkpoint"
  print_info "$prefix - Creating checkpoint at $checkpoint_dir for app $app_name running on port $http_port (CRIU)."
  if [ -d "$checkpoint_dir" ]; then
    sudo rm -r "$checkpoint_dir"
  fi
  mkdir -p "$checkpoint_dir"
  local payara_pid="$(payara_find $http_port)"
  sudo criu-ns dump -vvvv --shell-job -t $payara_pid --log-file criu-dump.log --tcp-close --images-dir "$checkpoint_dir"
  sudo chmod -R a+rw "$checkpoint_dir"
}

checkpoint_restore() {
  ccr_setup_vars
  local prefix="CHECKPOINT::RESTORE"
  local app_name=$1
  local checkpoint_dir="$PAYARA_VERSION_DIR/$app_name/checkpoint"
  print_info "$prefix - Restoring checkpoint at $checkpoint_dir for app $app_name (CRIU)."
  sudo criu-ns restore -vvvv --shell-job --log-file criu-restore.log --tcp-close --images-dir "$checkpoint_dir"
}

payara_kill() {
  local prefix="PAYARA::KILL"
  local http_port=$1
  local payara_pid="$(payara_find $http_port)"
  if [[ ! -z "$payara_pid" ]]; then
    print_info "$prefix - Killing payara micro with pid '$payara_pid' running on http port '$http_port'";
    kill -SIGKILL $payara_pid;
  else
    print_warn "$prefix - Can't find running payara micro on http port '$http_port'!"
  fi
}

payara_find() {
  local http_port=$1
  local pid=`ps -aux | grep java | grep launch-micro | grep -w $http_port | awk '{print $2}'`
  echo "$pid"
}

get_cpu_cores() {
  local cores=`cat /proc/cpuinfo | grep "cpu cores" | head -1 | awk '{print $4}'`
  echo "$cores"
}

payara_warm_up() {
  local prefix="PAYARA::WARM UP"
  local payara_root=$1
  is_payara_warmed_up $payara_root
  local payara_warmed_up=$?
  if [ ! $payara_warmed_up -eq 0 ]; then
    print_info "$prefix -  Payara at $payara_root is not warmed up (AppCDS). Warming up...";
    java\
      -jar "$PAYARA_JAR" \
	    --nocluster\
	    --rootDir "$payara_root"\
	    --outputlauncher
    java\
      -XX:DumpLoadedClassList="$payara_root/$PAYARA_WARMED_UP_CLASSES_LST"\
	    -jar "$payara_root/$PAYARA_WARMED_UP_LAUNCHER"\
	    --nocluster\
	    --warmup
    java\
      -Xshare:dump\
	    -XX:SharedClassListFile="$payara_root/$PAYARA_WARMED_UP_CLASSES_LST"\
	    -XX:SharedArchiveFile="$payara_root/$PAYARA_WARMED_UP_CLASSES_JSA"\
	    -jar "$payara_root/$PAYARA_WARMED_UP_LAUNCHER"\
	    --nocluster
  else
    print_info "$prefix - Payara at $payara_root is warmed up (AppCDS).";
  fi
}

is_payara_warmed_up() {
  local payara_root=$1
  if [ -f "$payara_root/$PAYARA_WARMED_UP_LAUNCHER" ] && [ -f "$payara_root/$PAYARA_WARMED_UP_CLASSES_JSA" ]; then
    return 0
  else
    return 1
  fi
}

is_app_ready() {
  local status_url=$1
  local expected_status=200
  local max_wait_count=80
  check_response_code $status_url $expected_status $max_wait_count
  return $?;
}

check_response_code() {
  local prefix="CHECK::APP"
  local status_url=$1
  local expected_status=$2
  local max_wait_count=$3
  local next_wait_count=1
  local sleep_time=0.25 # 250ms
  until [ $next_wait_count -gt $max_wait_count ] || [ $(curl -s -o /dev/null -w "%{http_code}" $status_url) == $expected_status ]; do
    print_info "$prefix - Waiting for application to handle http traffic. Checking with status_url $status_url. Check $next_wait_count of $max_wait_count."
    sleep $sleep_time
    (( next_wait_count++ ))
  done
  if [ $next_wait_count -gt $max_wait_count ]
  then
    print_error "$prefix - Application is not ready to handle http traffic. Waited $max_wait_count x $sleep_time sec. Checked status_url was $status_url."
    return 1;
  else
    local waited=$((next_wait_count-1))
    print_info "$prefix - Application is ready to handle http traffic. Waited $waited x $sleep_time sec. Checked status_url was $status_url."
    return 0;
  fi
}

backend_run() {
  ccr_setup_vars
  local app_name="backend"
  local http_port=8080
  local debug_port=9009
  local status_url="http://localhost:$http_port/ccr/appmonitoring/ping"
  local app_path="$CCR/ccr/backend/target/backend"
  local payara_options="--prebootcommandfile $CCR/ccr/backend/src/main/resources/pre-boot-commands.txt"
  app_run $app_name $http_port $debug_port $status_url "$app_path" "$payara_options"
}

app_run() {
  local app_name=$1
  local http_port=$2
  local debug_port=$3
  local status_url=$4
  local app_path="$5"
  local payara_options="$6"
  local checkpoint_dir="$PAYARA_VERSION_DIR/$app_name/checkpoint"
  local payara_root="$PAYARA_VERSION_DIR/$app_name/payara-root"
  payara_kill $http_port
  is_criu_available
  local criu_available=$?
  if [ $criu_available -eq 0 ] && [ -d "$checkpoint_dir" ] && [ -d "$payara_root" ]; then
    checkpoint_restore $app_name &
    is_app_ready $status_url
  else
    payara_run $app_name $http_port $debug_port "$app_path" "$payara_options" &
    is_app_ready $status_url
    local app_ready=$?
    if [ $criu_available -eq 0 ] && [ $app_ready -eq 0 ]; then
      checkpoint_create $app_name $http_port
      checkpoint_restore $app_name &
      is_app_ready $status_url
    fi
  fi
}

backend_payara_clean() {
  payara_clean backend
}

backend_redeploy() {
  app_redeploy $CCR/ccr/backend/target/backend
}

is_backend_ready() {
  is_app_ready http://localhost:8080/ccr/appmonitoring/ping
}

# print
COLOR_GREEN='\033[1;34m'
COLOR_BROWN='\033[0;33m'
COLOR_RED='\033[0;31m'
FORMAT_BOLD='\033[1m'
FORMAT_RESET='\033[0m'

print_info() {
  echo -e "${COLOR_GREEN}[INFO]${FORMAT_RESET} ------------------------------------------------------------------------"
  echo -e "${COLOR_GREEN}[INFO]${FORMAT_RESET}${FORMAT_BOLD} $1 ${FORMAT_RESET}"
  echo -e "${COLOR_GREEN}[INFO]${FORMAT_RESET} ------------------------------------------------------------------------"
}

print_warn() {
  echo -e "${COLOR_BROWN}[WARNING]${FORMAT_RESET} ------------------------------------------------------------------------"
  echo -e "${COLOR_BROWN}[WARNING]${FORMAT_RESET}${FORMAT_BOLD} $1 ${FORMAT_RESET}"
  echo -e "${COLOR_BROWN}[WARNING]${FORMAT_RESET} ------------------------------------------------------------------------"
}

print_error() {
  echo -e "${COLOR_RED}[ERROR]${FORMAT_RESET} ------------------------------------------------------------------------"
  echo -e "${COLOR_RED}[ERROR]${FORMAT_RESET}${FORMAT_BOLD} $1 ${FORMAT_RESET}"
  echo -e "${COLOR_RED}[ERROR]${FORMAT_RESET} ------------------------------------------------------------------------"
}
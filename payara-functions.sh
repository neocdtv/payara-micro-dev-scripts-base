#!/bin/bash

# set variables, if not present
TMP_DIR="/tmp"
PAYARA_VERSION="5.2020.4";
PAYARA_DIR="$TMP_DIR/payara-micro"
PAYARA_VERSION_DIR="$PAYARA_DIR/$PAYARA_VERSION"
PAYARA_CHECKPOINT_DIR="$PAYARA_VERSION_DIR/checkpoint-image"
PAYARA_ROOT_DIR="$PAYARA_VERSION_DIR/payara-root"
PAYARA_JAR="$PAYARA_VERSION_DIR/payara-micro-$PAYARA_VERSION.jar"
PAYARA_WARM_UP_CLASSES_LST="$PAYARA_VERSION_DIR/payara-classes.lst"
PAYARA_WARM_UP_CLASSES_JSA="$PAYARA_VERSION_DIR/payara-classes.jsa"
PAYARA_WARM_UP_LAUNCHER="$PAYARA_ROOT_DIR/launch-micro.jar"

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
  local http_port=$1
  local debug_port=$2
  payara_download
  payara_warm_up
  echo "RUNNING" > "$PAYARA_ROOT_DIR/docroot/status.txt"
  java\
    -XX:-UsePerfData\
	  -XX:+TieredCompilation\
	  -XX:TieredStopAtLevel=1\
	  -XX:+UseParallelGC\
	  -XX:ActiveProcessorCount=$(get_cpu_cores)\
	  -XX:CICompilerCount=$(get_cpu_cores)\
	  -Xshare:on\
	  -XX:SharedArchiveFile="$PAYARA_WARM_UP_CLASSES_JSA"\
	  -Xlog:class+path=info\
	  -Xverify:none\
	  -Xdebug\
	  -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address="$debug_port"\
	  -Dorg.glassfish.deployment.trace\
	  -jar "$PAYARA_WARM_UP_LAUNCHER"\
	  --nocluster\
	  --contextroot "/"\
	  --port "$http_port" &
}

app_deploy() {
  print_info "APP::DEPLOY"
  local app_path="$1"
  local app_name="$2"
  ln -s "$app_path" "$PAYARA_ROOT_DIR/autodeploy/$2"
}

app_redeploy() {
  print_info "APP::REDEPLOY"
  # check if deployed
  # update .reload
  echo "bla"
}

payara_clean() {
  print_info "PAYARA::CLEAN"
  sudo rm -fvr "$PAYARA_ROOT_DIR"
  sudo rm -fvr "$PAYARA_WARM_UP_CLASSES_LST"
  sudo rm -fvr "$PAYARA_WARM_UP_CLASSES_JSA"
}

checkpoint_clean() {
  print_info "CHECKPOINT::CLEAN"
  sudo rm -fvr "$PAYARA_CHECKPOINT_DIR"
}

checkpoint_create() {
  print_info "CHECKPOINT::CREATE"
  local app_name=$1
  local http_port=$2
  local checkpoint_dir="$PAYARA_CHECKPOINT_DIR/$app_name"
  sudo rm -r "$checkpoint_dir"
  mkdir -p "$checkpoint_dir"
  local payara_pid="$(payara_find $http_port)"
  sudo criu dump -vvvv --shell-job -t $payara_pid --log-file criu-dump.log --tcp-established --images-dir "$checkpoint_dir"
}

checkpoint_restore() {
  print_info "CHECKPOINT::RESTORE"
  sudo criu-ns restore -vvvv --shell-job --log-file criu-restore.log --tcp-established --images-dir "$PAYARA_CHECKPOINT_DIR"
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
  is_payara_warmed_up
  local payara_warmed_up=$?
  if [ ! $payara_warmed_up -eq 0 ]; then
    print_info "$prefix -  Payara $PAYARA_VERSION not warmed up (AppCDS). Warming up...";
    java\
      -jar "$PAYARA_JAR" \
	    --nocluster\
	    --rootDir "$PAYARA_ROOT_DIR"\
	    --outputlauncher
    java\
      -XX:DumpLoadedClassList="$PAYARA_WARM_UP_CLASSES_LST"\
	    -jar "$PAYARA_WARM_UP_LAUNCHER"\
	    --nocluster\
	    --warmup
    java\
      -Xshare:dump\
	    -XX:SharedClassListFile="$PAYARA_WARM_UP_CLASSES_LST"\
	    -XX:SharedArchiveFile="$PAYARA_WARM_UP_CLASSES_JSA"\
	    -jar "$PAYARA_WARM_UP_LAUNCHER"\
	    --nocluster
  else
    print_info "$prefix - Payara $PAYARA_VERSION is warmed up (AppCDS).";
  fi
}

is_payara_warmed_up() {
  if [ -f "$PAYARA_WARM_UP_LAUNCHER" ] && [ -f "$PAYARA_WARM_UP_CLASSES_LST" ] && [ -f "$PAYARA_WARM_UP_CLASSES_JSA" ]; then
    return 0
  else
    return 1
  fi
}

app_run() {
  local app_name=$1
  local http_port=$2
  local checkpoint_dir="$PAYARA_CHECKPOINT_DIR/$app_name"
  is_criu_available
  local criu_available=$?
  if [ $criu_available -eq 0 ] && [ -d "$checkpoint_dir" ] && [ -d "$PAYARA_ROOT_DIR" ]; then
    app_restore
  else
    payara_run
    is_app_ready
    local app_ready=$?
    if [ $criu_available -eq 0 ] && [ $app_ready -eq 0 ]; then
      app_dump
      app_restore
    fi
  fi
}

is_app_ready() {
  local url="http://localhost:8080/status.html"
  local expected_status=200
  local max_wait_count=80
  check_response_code $url $expected_status $max_wait_count
  return $?;
}

is_payara_ready() {
  local url="http://localhost:$APP_HTTP_PORT/status.txt"
  local expected_status=200
  local max_wait_count=80
  check_response_code $url $expected_status $max_wait_count
  return $?;
}

check_response_code() {
  local prefix="CHECK::APP"
  local url=$1
  local expected_status=$2
  local max_wait_count=$3
  local next_wait_count=1
  local sleep_time=0.25 # 250ms
  until [ $next_wait_count -gt $max_wait_count ] || [ $(curl -s -o /dev/null -w "%{http_code}" $url) == $expected_status ]; do
    print_info "$prefix - Waiting for application to handle http traffic. Checking with url $url. Check $next_wait_count of $max_wait_count."
    sleep $sleep_time
    (( next_wait_count++ ))
  done
  if [ $next_wait_count -gt $max_wait_count ]
  then
    print_error "$prefix - Application is not ready to handle http traffic. Waited $max_wait_count x $sleep_time sec. Checked url was $url."
    return 1;
  else
    local waited=$((next_wait_count-1))
    print_info "$prefix - Application is ready to handle http traffic. Waited $waited x $sleep_time sec. Checked url was $url."
    return 0;
  fi
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
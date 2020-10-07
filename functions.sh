#!/bin/bash

# set variables, if not present
TMP_DIR="/tmp"
PAYARA_VERSION="5.2020.4";
PAYARA_DIR="$TMP_DIR/payara-micro"
PAYARA_VERSION_DIR="$PAYARA_DIR/$PAYARA_VERSION"
PAYARA_VERSION_CRIU_DIR="$PAYARA_VERSION_DIR/criu-image"
PAYARA_VERSION_ROOT_DIR="$PAYARA_VERSION_DIR/payara-root"
PAYARA_VERSION_JAR="$PAYARA_VERSION_DIR/payara-micro-$PAYARA_VERSION.jar"
PAYARA_WARM_UP_CLASSES_LST="$PAYARA_VERSION_DIR/payara-classes.lst"
PAYARA_WARM_UP_CLASSES_JSA="$PAYARA_VERSION_DIR/payara-classes.jsa"

APP_HTTP_PORT=8080
APP_DEBUG_PORT=5005
APP_DIR="$PAYARA_DIR/dummy_app"
APP_DIR_EXPLODED="$APP_DIR/target/dummy_app"

payara_download() {
  local prefix="PAYARA::DOWNLOAD"
  print_info $prefix
  # check for latests payara version (https://repo1.maven.org/maven2/fish/payara/extras/payara-micro/maven-metadata.xml metadata/versioning/latest or release?) and inform if differ from $PAYARA_VERSION
  if [ ! -f "$PAYARA_VERSION_JAR" ]; then
    print_info "$prefix - Payara $PAYARA_VERSION_JAR not available. Starting download..."
    mkdir -p "$PAYARA_VERSION_DIR"
    curl "https://repo1.maven.org/maven2/fish/payara/extras/payara-micro/$PAYARA_VERSION/payara-micro-$PAYARA_VERSION.jar" -o "$PAYARA_VERSION_JAR"
  else 
    print_info "$prefix - Payara $PAYARA_VERSION_JAR available. No download needed."
  fi
}

# TODO: how to get cpu count on linux?
# TODO: what to do with status.html?
payara_run() {
  print_info "PAYARA::RUN"
  mkdir -p "$APP_DIR_EXPLODED/WEB-INF"
  echo "" > "$APP_DIR_EXPLODED/status.html"
  java  -XX:-UsePerfData\
	  -XX:+TieredCompilation\
	  -XX:TieredStopAtLevel=1\
	  -XX:+UseParallelGC\
	  -XX:ActiveProcessorCount=4\
	  -XX:CICompilerCount=4\
	  -Xshare:on\
	  -XX:SharedArchiveFile="$PAYARA_WARM_UP_CLASSES_JSA"\
	  -Xlog:class+path=info\
	  -Xverify:none\
	  -Xdebug\
	  -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address="$APP_DEBUG_PORT"\
	  -Dorg.glassfish.deployment.trace\
	  -jar "$PAYARA_VERSION_ROOT_DIR/launch-micro.jar"\
	  --deploy $APP_DIR_EXPLODED\
	  --nocluster\
	  --contextroot "/"\
	  --port "$APP_HTTP_PORT" &
}

payara_clean() {
  print_info "PAYARA::CLEAN"
  sudo rm -fvr "$PAYARA_MICRO_ROOT_DIR"
  sudo rm -fvr "$PAYARA_WARM_UP_CLASSES_LST"
  sudo rm -fvr "$PAYARA_WARM_UP_CLASSES_JSA"
}

checkpoint_clean() {
  print_info "CHECKPOINT::CLEAN"
  sudo rm -fvr "$PAYARA_VERSION_CRIU_DIR"
}

checkpoint_create() {
  print_info "CHECKPOINT::CREATE"
  mkdir -p "$PAYARA_VERSION_CRIU_DIR"
  local payara_pid="$(payara_find)"
  sudo criu dump -vvvv --shell-job -t $payara_pid --log-file criu-dump.log --tcp-established --images-dir "$PAYARA_VERSION_CRIU_DIR"
}

checkpoint_restore() {
  print_info "CHECKPOINT::RESTORE"
  sudo criu-ns restore -vvvv --shell-job --log-file criu-restore.log --tcp-established --images-dir "$PAYARA_VERSION_CRIU_DIR"
}

payara_kill() {
  local prefix="PAYARA::KILL"
  local payara_pid="$(payara_find)"
  if [[ ! -z "$payara_pid" ]]; then
    print_info "$prefix - Killing payara micro with pid '$payara_pid'";
    kill -SIGKILL $payara_pid;
  else
    print_warn "$prefix - Can't find running payara micro process!"
  fi
}

payara_find() {
  local pid=`ps -aux | grep java | grep launch-micro | awk '{print $2}'`
  echo "$pid"
}

payara_warm_up() {
  java  -jar "$PAYARA_VERSION_JAR" \
	  --nocluster\
	  --rootDir "$PAYARA_VERSION_ROOT_DIR"\
	  --outputlauncher
  java  -XX:DumpLoadedClassList="$PAYARA_WARM_UP_CLASSES_LST"\
	  -jar "$PAYARA_VERSION_ROOT_DIR/launch-micro.jar"\
	  --nocluster\
	  --warmup
  java  -Xshare:dump\
	  -XX:SharedClassListFile="$PAYARA_WARM_UP_CLASSES_LST"\
	  -XX:SharedArchiveFile="$PAYARA_WARM_UP_CLASSES_JSA"\
	  -jar "$PAYARA_VERSION_ROOT_DIR/launch-micro.jar"\
	  --nocluster
}

app_run() {
  # TODO:
  # if app running do nothing, how to check with is_app_ready
  # else
  is_criu_available
  local criu_available=$?
  if [ $criu_available -eq 0 ] && [ -d "$PAYARA_VERSION_CRIU_DIR" ] && [ -d "$PAYARA_VERSION_ROOT_DIR" ]; then
    app_restore
    app_redeploy
  else
    payara_download
    # TODO: check if is warmed up, if not warm up
    payara_run # warmed up
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
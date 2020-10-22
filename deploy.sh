#!/bin/bash
set -e
#

OCP_RELEASE="4.5"
ARTIFACTS_VERSION="release-4.5"
#ARTIFACTS_VERSION="v4.5.3"
#ARTIFACTS_VERSION="master"


TF='./terraform'


TMPDIR=${TMPDIR:-"/tmp"}
LOGFILE=".ocp4-upi-powervs.log"
GIT_URL="https://github.com/ocp-power-automation/ocp4-upi-powervs"
ARTIFACTS_DIR="automation"
source ./errors.sh

DISTRO=""
CLI_PATH='./ibmcloud'

#------------------------------------------------------------------------------
#-- ${FUNCNAME[1]} == Calling function's name
#-- Colors escape seqs
YEL='\033[1;33m'
CYN='\033[0;36m'
GRN='\033[1;32m'
RED='\033[1;31m'
PUR="\033[1;35m"
NRM='\033[0m'

#trap ctrl_c INT
#function ctrl_c() {
#  while true; do
#    read -p "Are you sure you want to interupt the process (Y/N)?" yn
#    case $yn in
#    Y | y | Yes | yes)
#      exit
#      ;;
#    N | n | No | no)
#      echo "Continue with ongoing process..."
#      return
#      ;;
#    *) echo "Please answer yes or no." ;;
#    esac
#  done
#}

function log {
  echo -e "${CYN}[${FUNCNAME[1]}]${NRM} $1"
}
function warn {
  echo -e "${YEL}[${FUNCNAME[1]}]${NRM} ${YEL}WARN${NRM}: $1"
}
function failure {
  echo -e "${PUR}[${FUNCNAME[1]}]${NRM} ${PUR}FAILED${NRM}: $1"
}
function success {
  echo -e "${GRN}[${FUNCNAME[1]}]${NRM} ${GRN}SUCCESS${NRM}: $1"
}
function error {
  echo -e "${RED}[${FUNCNAME[1]}]${NRM} ${RED}ERROR${NRM}: $1"
  ret_code=$2
  if [ "$ret_code" == "" ]; then
    ret_code=-1
  fi;
  exit $ret_code
}
function retry {
  tries=$1
  cmd=$2
  for i in $(seq 1 "$tries"); do
    echo "Attempt: $i/$tries"
    ret_code=0
    $cmd || ret_code=$?
    if [ $ret_code = 0 ]; then
      break
    elif [ "$i" == "$tries" ]; then
      error "All retry attempts failed! Please try running the script again after some time" $ret_code
    else
      sleep 1s
    fi
  done
}

function retry_terraform {
  tries=$1
  cmd=$2
  for i in $(seq 1 "$tries"); do
    fatal_errors=()
    LOG_FILE="../${LOGFILE}_$i"
    echo "Attempt: $i/$tries"
    {
    echo "========================"
    echo "Attempt: $i/$tries"
    echo "$cmd"
    echo "========================"
    } >> "$LOG_FILE"
    $cmd >> "$LOG_FILE" 2>&1 &
    tpid=$!

    while [ "$(ps | grep "$tpid")" != "" ]; do
      sleep 30
      # CAN PROVIDE HACKS HERE
      # Keep check on bastion
      # Keep check on rhcos nodes
    done
    errors=$(grep "Error:" "$LOG_FILE" | sort | uniq)
    if [ ${#errors[@]} -eq 0 ]; then
      # terraform command completed without any errors
      break
    else
      # Handle errors
      # Input variables are invalid
      # Can a re-run help?
      # Bastion is not creating

      # Catch known issues
      find_fatal_errors
      if [ ${#fatal_errors[@]} -gt 0 ]; then
        failure "Please correct the following errors and run the script again"
        error "${fatal_errors[@]}"
      fi

      # All tries exhausted
      if [ "$i" == "$tries" ]; then
        log "${errors[@]}"
        error "Terraform command failed after $tries attempts! Please destroy and run the script again after some time"
      fi

      # Nothing to do other than retry
      log "${errors[@]}"
      warn "Some issues seens while running the terraform command. Attempting to run again..."
      sleep 10s
    fi
  done
  log "Completed running the terraform command."
}

function setup_terraform {
  TF_LATEST=$(curl -s https://api.github.com/repos/hashicorp/terraform/releases/latest | grep tag_name | cut -d'"' -f4)
  EXT_PATH=$(which terraform 2> /dev/null || true)

  if [[ -f $TF && $($TF version | grep 'Terraform v0') == "Terraform ${TF_LATEST}" ]]; then
    log "Terraform latest version already installed"
  elif [[ -n "$EXT_PATH" && $($EXT_PATH version | grep 'Terraform v0') == "Terraform ${TF_LATEST}" ]]; then
    rm -f "$TF"
    ln -s "$EXT_PATH" "$TF"
    log "Terraform latest version already installed on the system"
  else
    log "Installing Terraform binary..."
    retry 5 "curl --connect-timeout 30 -fsSL https://releases.hashicorp.com/terraform/${TF_LATEST:1}/terraform_${TF_LATEST:1}_${OS}_amd64.zip -o $TMPDIR/terraform.zip"
    unzip -o "$TMPDIR"/terraform.zip  >/dev/null 2>&1
    rm -f "$TMPDIR"/terraform.zip
  fi
  $TF version
}

function init_terraform {
  log "Initializing Terraform plugins..."
  retry 5 "$TF init"
  log "Validating Terraform code..."
  $TF validate
}

function verify_data {
  if [ -s "./pull-secret.txt" ]; then
    log "Found pull-secret.txt in current directory"
    cp pull-secret.txt ./"$ARTIFACTS_DIR"/data/
  else
    error "No pull-secret.txt file found in current directory"
  fi
  if [ -f "./id_rsa" ] && [ -f "./id_rsa.pub" ]; then
    log "Found id_rsa & id_rsa.pub in current directory"
    cp ./id_rsa ./id_rsa.pub ./"$ARTIFACTS_DIR"/data/
  elif [ -f "$HOME/.ssh/id_rsa" ] && [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    log "Found id_rsa & id_rsa.pub in $HOME/.ssh directory"
    cp  "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_rsa.pub" ./"$ARTIFACTS_DIR"/data/
  else
    warn "No id_rsa & id_rsa.pub found in current directory, Creating new key-pair..."
    ssh-keygen -t rsa -f ./id_rsa -N ''
  fi
}

function verify_var_file {
  if [ -s "$1" ]; then
    log "Found $1"
  else
    error "File $1 does not exist"
  fi
}

function setup_poweriaas() {
  PLUGIN_OP=$("$CLI_PATH" plugin list -q | grep power-iaas || true)
  if [[ "$PLUGIN_OP" != "" ]]; then
    log "Plugin power-iaas already installed"
  else
    log "Installing power-iaas plugin..."
    $CLI_PATH plugin install power-iaas -f -q > /dev/null 2>&1
  fi
}

function setup_ibmcloudcli() {
  CLI_LATEST=$(curl -s https://api.github.com/repos/IBM-Cloud/ibm-cloud-cli-release/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/v//')
  EXT_PATH=$(which ibmcloud 2> /dev/null || true)

  if [[ -f $CLI_PATH && $($CLI_PATH -v | sed 's/.*version //' | sed 's/+.*//') == "${CLI_LATEST}" ]]; then
    log "IBM-Cloud CLI latest version already installed"
  elif [[ -n "$EXT_PATH" && $($EXT_PATH -v | sed 's/.*version //' | sed 's/+.*//') == "${CLI_LATEST}" ]] ; then
    rm -f "$CLI_PATH"
    ln -s "$EXT_PATH" "$CLI_PATH"
    log "IBM-Cloud CLI latest version already installed on the system"
  else
    # Download the latest
    CLI_REF=$(curl -s https://clis.cloud.ibm.com/download/bluemix-cli/latest/"${CLI_OS}"/archive)
    CLI_URL=$(echo "$CLI_REF" | sed 's/.*href=\"//' | sed 's/".*//')
    log "Installing the latest version of IBM-Cloud CLI..."
    retry 2 "curl -fsSL $CLI_URL -o $TMPDIR/$(basename "$CLI_URL")"
    if [[ "$OS" != "windows" ]]; then
      tar -xvzf "$TMPDIR/$(basename "$CLI_URL")" >/dev/null 2>&1
    else
      unzip -o "$TMPDIR/$(basename "$CLI_URL")" >/dev/null 2>&1
    fi
    mv -f ./IBM_Cloud_CLI/ibmcloud "${CLI_PATH}"
    rm -rf "$TMPDIR"/IBM_Cloud_CLI* ./IBM_Cloud_CLI*
  fi
  ${CLI_PATH} -v
}

function setup_artifacts() {
  log "Downloading code artifacts $ARTIFACTS_VERSION in ./$ARTIFACTS_DIR"
  retry 2 "curl -fsSL $GIT_URL/archive/$ARTIFACTS_VERSION.zip -o ./automation.zip"
  unzip -o "./automation.zip" > /dev/null 2>&1
  rm -rf ./"$ARTIFACTS_DIR" ./automation.zip
  mv -f "ocp4-upi-powervs-$ARTIFACTS_VERSION" ./"$ARTIFACTS_DIR"
}

function apply {
  [ "${CLOUD_API_KEY}" == "" ] && error "Please export CLOUD_API_KEY"
  # Run setup if no artifacts
  [ ! -d $ARTIFACTS_DIR ] && warn "Cannot find artifacts directory... running setup command" && setup

  verify_data
  if [ -z "$vars" ] && [ -f "var.tfvars" ]; then
    vars="-var-file ../var.tfvars"
  else
    warn "No variables specified or var.tfvars does not exist.. running variables command" && variables
  fi
  export TF_VAR_ibmcloud_api_key="$CLOUD_API_KEY"

  cd ./"$ARTIFACTS_DIR"
  TF='../terraform'
  init_terraform
  log "Running terraform apply command... please wait"
  retry_terraform 2 "$TF apply $vars -auto-approve -input=false"
  log "Congratulations! Terraform apply completed"
  $TF output

}

function destroy {
  [ "${CLOUD_API_KEY}" == "" ] && error "Please export CLOUD_API_KEY"
  # Run setup if no artifacts
  [ ! -d $ARTIFACTS_DIR ] && setup

  if [ -z "$vars" ] && [ -f "var.tfvars" ]; then
    vars="-var-file ../var.tfvars"
  else
    warn "No variables specified or var.tfvars does not exist.. running variables command"
    variables
  fi
  export TF_VAR_ibmcloud_api_key="$CLOUD_API_KEY"

  cd ./"$ARTIFACTS_DIR"
  TF='../terraform'
  init_terraform
  log "Running terraform destroy command... please wait"
  retry 2 "$TF destroy $vars -auto-approve -input=false"
  log "Done! Terraform destroy completed"
}

function question {
  value=""
  # question to ask
  message=$1
  # array of options eg: "a b c".
  options=($2)
  len=${#options[@]}
  force_select=$3

  if [[ $len -gt 1 ]] || [[ -n "$force_select" ]]; then
    # Multi-choice
    # Allow select prompt even for if a single option.
    log "> $message"
    select value in ${options[@]}
    do
    if [ "$value" == "" ]; then
      echo 'Invalid value... please re-select'
    else
      break
    fi
    done
  elif [[ $len -eq 1 ]]; then
    # Input question with default value
    # If only 1 option is sent then use it for default value prompt.
    log "> $message (${options[0]})"
    read -p "? " value
    [[ "${value}" == "" ]] && value="${options[0]}"
  else
    # Input question without any default value.
    log "> $message"
    read -p "? " value
  fi
  echo "- You have answered: $value"
}

function variables {
  [ "${CLOUD_API_KEY}" == "" ] && error "Please export CLOUD_API_KEY"
  # Run setup if no artifacts
  [ ! -d $ARTIFACTS_DIR ] && warn "Cannot find artifacts directory... running setup command" && setup

  VAR_TEMPLATE="./var.tfvars"
  rm -f "$VAR_TEMPLATE"

  log "Trying to login with the provided CLOUD_API_KEY..."
  $CLI_PATH login --apikey "$CLOUD_API_KEY" -q

  ALL_SERVICE_INSTANCE=$($CLI_PATH pi service-list --json| grep "Name" | cut -f4 -d'"')
  if [ -z "$ALL_SERVICE_INSTANCE" ]; then error "No service instance found in your account"; fi

  question "Select the Service Instance name to use:" "$ALL_SERVICE_INSTANCE" yes
  service_instance="$value"

  CRN=$($CLI_PATH pi service-list | grep "${service_instance}" | awk '{print $1}')
  $CLI_PATH pi service-target "$CRN"

  log "Gathering information from the selected Service Instance... Please wait"
  ZONE=$(echo "$CRN" | cut -f6 -d":")
  SERVICE_INSTANCE_ID=$(echo "$CRN" | cut -f8 -d":")

  ALL_IMAGES=$($CLI_PATH pi images --json | grep name | cut -f4 -d'"')
  # TODO: Filter out only pub-vlan from the list
  ALL_NETS=$($CLI_PATH pi nets --json| grep name | cut -f4 -d'"')
  ALL_OCP_VERSIONS=$(curl -sL https://mirror.openshift.com/pub/openshift-v4/ppc64le/clients/ocp/| grep $OCP_RELEASE | cut -f7 -d '>' | cut -f1 -d '/')


  # TODO: Get region from a map of `zone:region` or any other good way
  {
    echo "ibmcloud_region = \"tor\""
    echo "ibmcloud_zone = \"${ZONE}\""
    echo "service_instance_id = \"${SERVICE_INSTANCE_ID}\""
  } >> $VAR_TEMPLATE

  # RHEL image name
  question "Select the RHEL image to use for bastion node:" "$ALL_IMAGES" yes
  echo "rhel_image_name =  \"${value}\"" >> $VAR_TEMPLATE

  # RHCOS image name
  question "Select the RHCOS image to use for cluster nodes:" "$ALL_IMAGES" yes
  echo "rhcos_image_name =  \"${value}\"" >> $VAR_TEMPLATE

  # PowerVS private network
  question "Select the private network to use:" "$ALL_NETS" yes
  echo "network_name =  \"${value}\"" >> $VAR_TEMPLATE

  # OpenShift mirror links
  question "Select the OCP version to use:" "$ALL_OCP_VERSIONS" yes
  OCP_IURL="https://mirror.openshift.com/pub/openshift-v4/ppc64le/clients/ocp/${value}/openshift-install-linux.tar.gz"
  OCP_CURL="https://mirror.openshift.com/pub/openshift-v4/ppc64le/clients/ocp/${value}/openshift-client-linux.tar.gz"
  echo "openshift_install_tarball =  \"${OCP_IURL}\"" >> $VAR_TEMPLATE
  echo "openshift_client_tarball =  \"${OCP_CURL}\"" >> $VAR_TEMPLATE


  # Cluster id
  question "Enter a short name to identify the cluster" "test-ocp"
  echo "cluster_id_prefix = \"${value}\"" >> $VAR_TEMPLATE

  # Cluster domain
  question "Enter a domain name for the cluster" "ibm.com"
  echo "cluster_domain = \"${value}\"" >> $VAR_TEMPLATE

  # Storage
  question "Do you need NFS storage to be configured?" "yes no"
  if [ "${value}" == "yes" ]; then
    question "Enter the NFS volume size(GB)" "300"
    echo "storage_type = \"nfs\"" >> $VAR_TEMPLATE
    echo "volume_size = \"${value}\"" >> $VAR_TEMPLATE
  elif [ "${value}" == "no" ]; then
    echo "storage_type = \"none\"" >> $VAR_TEMPLATE
  fi

  # Nodes configuration
  variables_nodes

  question "Enter RHEL subscription username for bastion nodes"
  echo "rhel_subscription_username = \"${value}\"" >> $VAR_TEMPLATE
  question "Enter the password for above username"
  echo "rhel_subscription_password = \"${value}\"" >> $VAR_TEMPLATE
}

function variables_nodes {

  question "Do you want to use the default configuration for all the cluster nodes?" "yes no"
  if [ "${value}" == "yes" ]; then
    {
      echo "bastion = {memory = \"16\", processors = \"1\", \"count\" = 1}"
      echo "bootstrap = {memory = \"16\", processors = \"0.5\", \"count\" = 1}"
      echo "master = {memory = \"16\", processors = \"0.5\", \"count\" = 3}"
      echo "worker = {memory = \"32\", processors = \"0.5\", \"count\" = 2}"
    } >> $VAR_TEMPLATE
    return
  fi

  # Bastion node config
  question "Do you want to use the default configuration for bastion node? (memory=16g processors=1 count=1)" "yes no"
  if [ "${value}" == "yes" ]; then
    echo "bastion = {memory = \"16\", processors = \"1\", \"count\" = 1}" >> $VAR_TEMPLATE
  else
    question "Enter the memory required for bastion nodes" "16"
    memory="${value}"
    question "Enter the processors required for bastion nodes" "1"
    proc="${value}"
    question "Select the count of bastion nodes" "1 2"
    count="${value}"
    echo "bastion = {memory = \"$memory\", processors = \"$proc\", \"count\" = $count}" >> $VAR_TEMPLATE
  fi

  # Bootstrap node config
  question "Do you want to use the default configuration for bootstrap node? (memory=16 processors=0.5)" "yes no"
  if [ "${value}" == "yes" ]; then
    echo "bootstrap = {memory = \"16\", processors = \"0.5\", \"count\" = 1}" >> $VAR_TEMPLATE
  else
    question "Enter the memory required for bootstrap node" "16"
    memory="${value}"
    question "Enter the processors required for bootstrap node" "0.5"
    proc="${value}"
    echo "bootstrap = {memory = \"$memory\", processors = \"$proc\", \"count\" = 1}" >> $VAR_TEMPLATE
  fi

  # Master nodes config
  question "Do you want to use the default configuration for master nodes? (memory=16 processors=1 count=3)" "yes no"
  if [ "${value}" == "yes" ]; then
    echo "master = {memory = \"16\", processors = \"0.5\", \"count\" = 3}" >> $VAR_TEMPLATE
  else
    question "Enter the memory required for master nodes" "16"
    memory="${value}"
    question "Enter the processors required for master nodes" "0.5"
    proc="${value}"
    question "Select the count of master nodes" "3 5"
    count="${value}"
    echo "master = {memory = \"$memory\", processors = \"$proc\", \"count\" = $count}" >> $VAR_TEMPLATE
  fi

  # Worker nodes config
  question "Do you want to use the default configuration for worker nodes? (memory=32 processors=1 count=2)" "yes no"
  if [ "${value}" == "yes" ]; then
    echo "worker = {memory = \"32\", processors = \"0.5\", \"count\" = 2}" >> $VAR_TEMPLATE
  else
    question "Enter the memory required for worker nodes" "32"
    memory="${value}"
    question "Enter the processors required for worker nodes" "0.5"
    proc="${value}"
    question "Enter the count of worker nodes" "2"
    count="${value}"
    echo "worker = {memory = \"$memory\", processors = \"$proc\", \"count\" = $count}" >> $VAR_TEMPLATE
  fi
}

function setup {
  if [[ "$OS" != "windows" ]]; then
    log "Installing dependency packages"
    if [[ "$OS" == "darwin" ]]; then
      $PACKAGE_MANAGER cask install osxfuse XQuartz > /dev/null 2>&1      
    else
      $PACKAGE_MANAGER update -y > /dev/null 2>&1
    fi
    $PACKAGE_MANAGER install curl unzip > /dev/null 2>&1
  fi
  mkdir -p "$TMPDIR"
  setup_ibmcloudcli
  setup_poweriaas
  setup_terraform
  setup_artifacts
}

function help {
  cat <<-EOF

Automation for deploying OpenShift 4.X on PowerVS

Usage:
  ./deploy.sh [command] [<args> <value>]

Available commands:
  setup       Install all required packages/binaries in current directory
  variables   Interactive way to populate the variables file
  create      Create an OpenShift cluster
  destroy     Destroy an OpenShift cluster
  help        Help about any command

Where <args>:
  -var        Terraform variable to be passed to the apply/destroy command
  -var-file   Terraform variable file name in current directory. (By default using var.tfvars)
  -trace      Enable verbose tracing of all activity

Submit any issues to : ${GIT_URL}/issues

EOF
  exit 0
}

function main {
  # Clean up log files
  rm -rf "${LOGFILE}"*
  vars=""

  # Only use sudo if not running as root
  [ "$(id -u)" -ne 0 ] && SUDO=sudo || SUDO=""

  PLATFORM=$(uname)
  case "$PLATFORM" in
    "Darwin")
      OS="darwin"
      CLI_OS="osx"
      PACKAGE_MANAGER="brew"
      ;;
    "Linux")
      # Linux distro, e.g "Ubuntu", "RedHatEnterpriseWorkstation", "RedHatEnterpriseServer", "CentOS", "Debian"
      OS="linux"
      CLI_OS="linux64"
      DISTRO=$(lsb_release -ds 2>/dev/null || cat /etc/*release 2>/dev/null | head -n1 || uname -om || echo "")
      if [[ "$DISTRO" != *Ubuntu* &&  "$DISTRO" != *Red*Hat* && "$DISTRO" != *CentOS* && "$DISTRO" != *Debian* && "$DISTRO" != *RHEL* && "$DISTRO" != *Fedora* ]]; then
        warn "Linux has only been tested on Ubuntu, RedHat, Centos, Debian and Fedora distrubutions please let us know if you use this utility on other Distros"
      fi
      if [[ "$DISTRO" == *Ubuntu* || "$DISTRO" == *Debian*  ]]; then
        PACKAGE_MANAGER="$SUDO apt-get"
      elif [[ "$DISTRO" == *Fedora* ]]; then
        PACKAGE_MANAGER="$SUDO dnf"
      else
        PACKAGE_MANAGER="$SUDO yum"
      fi
      ;;
    "MINGW64"* | "CYGWIN"*)
      OS="windows"
      CLI_OS="win64"
      ;;
    *)
      warn "Only MacOS and Linux systems are supported"
      error "Unsupported platform: ${PLATFORM}"
      exit 1
      ;;
  esac

  # Parse commands and arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
    "-trace")
      warn "Enabling verbose tracing of all activity"
      set -x
      ;;
    "-var")
      shift
      var="$1"
      vars+=" -var $var"
      ;;
    "-var-file")
      shift
      varfile="$1"
      verify_var_file "$varfile"
      vars+=" -var-file ../$varfile"
      ;;
    "setup")
      ACTION="setup"
      ;;
    "variables")
      ACTION="variables"
      ;;
    "create")
      ACTION="create"
      ;;
    "destroy")
      ACTION="destroy"
      ;;
    "help")
      ACTION="help"
      ;;
    esac
    shift
  done

  case "$ACTION" in
    "setup")      setup;;
    "variables")  variables;;
    "create")     apply;;
    "destroy")    destroy;;
    *)            help;;
  esac

  success "Script execution completed!"
}

main "$@"

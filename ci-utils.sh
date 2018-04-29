#!/bin/bash

## Builder Image functions
######################################
function builder_image_update() {
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" >/etc/apt/sources.list.d/kubernetes.list
    
    apt-get update -y

    ## Install Python, pip, jq, yq (for Yaml file Parsing), kubectl
    apt-get install -yqq apt-transport-https ca-certificates curl gnupg2 software-properties-common
    apt-get install -yqq jq python-setuptools python-dev build-essential kubectl
    easy_install pip && pip install yq

    ## kube config
    mkdir -p "$HOME/.build/" && echo "${KUBE_CONFIG}" > "$HOME/.build/kube.config"
}

function builder_image_install_sbt() {
    echo "deb http://dl.bintray.com/sbt/debian /" | tee -a /etc/apt/sources.list.d/sbt.list
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 642AC823
    apt-get update -y
    apt-get install sbt -y
    sbt sbtVersion
  
    echo "realm=Sonatype Nexus Repository Manager
host=$NEXUS_HOST
user=$NEXUS_USER
password=$NEXUS_PASS" > "$HOME/.sbt/.credentials"
}

function builder_image_install_docker() {
  curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"

  apt-get update
  apt-get install -y docker-ce

  builder_image_docker_registry_login
}

function builder_image_docker_registry_login() {
  echo -n "${DOCKER_REGISTRY_PASS}" |docker login "${DOCKER_REGISTRY}" --username="${DOCKER_REGISTRY_USER}" --password-stdin
}

## Project functions
######################################
function project_get_sbt_variable() {
    local project_var=$1; shift

    sbt -batch -no-colors "${project_var}" |tail -1|awk '{print $2}'
}

function project_get_mvn_variable() {
   local project_var=$1
   mvn help:evaluate -Dexpression="project.${project_var}" | tail -8 | head -1
}

function project_get_variable() {
    local project_var=$1; shift

    if [ -f build.sbt ]; then
        project_get_sbt_variable "${project_var}"
    elif [ -f pom.xml ]; then
        project_get_mvn_variable "${project_var}"
    fi
}


## Docker functions
######################################
function docker_image_build() {
    local dockerfile=$1; shift
    local kube_deployment_conf=$1; shift

    if [ -z "${CI_COMMIT_SHA}" ]; then
        echo "docker_image_build: FATAL: CI_COMMIT_SHA not set"
        exit 1
    fi
    
    local kube_deployment_resource_file=$(kube_resource_prep "${kube_resource_conf}")
    local kube_deployment_name=$(yq -cerM '.metadata.name' "${kube_deployment_resource_file}")
    local kube_deployment_image_name=$(yq -cerM '.spec.template.spec.containers[0].image'  "${kube_deployment_resource_file}")

    echo "docker_image_build: Building ${kube_deployment_image_name} Image using ${dockerfile}..."
    docker build -f "${dockerfile}" --tag "${kube_deployment_image_name}" .
}

function docker_image_push() {
    local kube_deployment_conf=$1; shift

    if [ ! -f "${kube_deployment_conf}" ]; then
        echo "docker_image_push: FATAL: \"${kube_deployment_conf}\" is provided as Kube Deployment File, but it is not found."
        exit 1
    fi
    if [ -z "${CI_COMMIT_SHA}" ]; then
        echo "docker_image_push: FATAL: CI_COMMIT_SHA not set"
        exit 1
    fi

    local kube_deployment_resource_file=$(kube_resource_prep "${kube_deployment_conf}")
    local kube_deployment_name=$(yq -cerM '.metadata.name' "${kube_deployment_resource_file}")
    local kube_deployment_image_name=$(yq -cerM '.spec.template.spec.containers[0].image'  "${kube_deployment_resource_file}")

    if [ -z "${CI_COMMIT_SHA}" ]; then
      echo "docker_image_push: FATAL: CI_COMMIT_SHA not set"
      exit 1
    fi
    echo "docker_image_push: Pushing ${kube_deployment_image_name}"
    docker push "${kube_deployment_image_name}"
}

## Kubernetes functions
######################################
function kube_resource_prep() {
    local kube_resource_conf=$1; shift

    local kube_deployment_name=$(yq -cerM '.metadata.name' "${kube_resource_conf}")

    mkdir -p "$HOME/.build"
    local kube_deployment_resource_file="$HOME/.build/deployment.${kube_deployment_name}.yml"
    perl -pe 's/\$(\{)?([a-zA-Z_]\w*)(?(1)\})/$ENV{$2}/g' < "${kube_resource_conf}" > "${kube_deployment_resource_file}"
    echo "${kube_deployment_resource_file}"
}

function kube_apply_and_wait() {
    local kube_namespace=$1; shift
    local kube_resource_conf=$1; shift

    kube_apply "${kube_namespace}" "${kube_resource_conf}"
    kube_deployment_wait "${kube_namespace}" "${kube_resource_conf}"
}

function kube_apply() {
    local kube_namespace=$1; shift
    local kube_resource_conf=$1; shift

    local kube_deployment_resource_file=$(kube_resource_prep "${kube_resource_conf}")
    local kube_deployment_name=$(yq -cerM '.metadata.name' "${kube_deployment_resource_file}")

    echo "KubeUtils: Deploying ${kube_resource_conf} to ${kube_namespace}..."
    export KUBECONFIG="$HOME/.build/kube.config"
    kubectl --namespace="${kube_namespace}" apply -f "${kube_deployment_resource_file}"
}

function kube_deployment_wait() {
    local kube_namespace=$1; shift
    local kube_resource_conf=$1; shift

    local kube_deployment_resource_file=$(kube_resource_prep "${kube_resource_conf}")
    local kube_deployment_name=$(yq -cerM '.metadata.name' "${kube_deployment_resource_file}")

    export KUBECONFIG="$HOME/.build/kube.config"
    echo "KubeUtils: Waiting for deployment to complete"
    for i in $(seq 1 30); do
        deployment_status=$(kubectl --namespace="${kube_namespace}" get deployment "${kube_deployment_name}" | tail -1)
        if [ -z "${deployment_status}" ]; then
            echo "kube_deployment_wait: FATAL: Unable to get Deployment Status."
            exit 1
        fi
        echo -e "${deployment_status}"
        deployment_desired=$(echo "${deployment_status}" | awk '{print $2}')
        deployment_up_to_date=$(echo "${deployment_status}" | awk '{print $4}')
        deployment_available=$(echo "${deployment_status}" | awk '{print $5}')
        if [ "${deployment_desired}" == "${deployment_up_to_date}" ] && [ "${deployment_desired}" == "${deployment_available}" ]; then
            break
        fi
        sleep 10
    done

    if [ "${deployment_desired}" == "${deployment_up_to_date}" ] && [ "${deployment_desired}" == "${deployment_available}" ]; then
        echo "kube_deployment_wait: Deployment complete."
    else
        echo "kube_deployment_wait: FATAL: Deployment did not complete in the allotted time."
        exit 1
    fi 
}

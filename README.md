ci-utils
========

# Description
A set of utilities to help with gitlab-ci Pipelines.

## Pre-Configuration
  - The top level of a project has either build.sbt or a pom.xml
  - Gitlab has the following variables set:
    - DOCKER_REGISTRY
    - DOCKER_REGISTRY_USER
    - DOCKER_REGISTRY_PASS
    - DOCKER_NAMESPACE
    - NEXUS_HOST
    - NEXUS_USER
    - NEXUS_PASS
    - KUBE_CONFIG
    
##Image functions:
  - builder_image_update
    - Installs: apt-transport-https, Python, jq, yq, kubectl
  - builder_image_install_sbt
    - Installs sbt and sets up  `$HOME/.sbt/.credentials`
  - builder_image_install_docker 
    - Installs Docker client and calls `builder_image_docker_registry_login`
  - builder_image_docker_registry_login
    - Logs in to private Docker Registry
    
## Project functions
  - project_get_variable
    - Takes a project variable name (ie. project.name) and calls `project_get_sbt_variable` or `project_get_mvn_variable`.
  - project_get_sbt_variable 
    - Takes a project variable name (ie. project.name) and gets its value from build.sbt.
  - project_get_mvn_variable 
    - Takes a project variable name (ie. project.name) and gets its value from pom.xml

## Docker functions
  - docker_image_build
    - Takes a Dockerfile and a K8s Deployment file and builds an image.
      - __Assumes that the first image mentioned in K8s deployment spec is the intended image name.__
  - docker_image_push
    - Takes a K8s Deployment file and pushes the docker image to the private docker registry.
      - __Assumes that the first image mentioned in K8s deployment spec is the intended image name.__
      
## Kubernetes functions
  - kube_resource_prep
    - Takes a K8s deployment file, replaces all Shell env variables with their respective values
  - kube_apply_and_wait
    - Takes a K8s deployment file, calls `kube_apply` and `kube_deployment_wait`
  - kube_apply
    - Takes a K8s deployment file and runs **kubectl apply**
  - kube_deployment_wait
    - Takes a K8s deployment file and **waits for 5 minutes** or until all pods have been updated.
    - __If Not all pods are running and available, exit with failure.__

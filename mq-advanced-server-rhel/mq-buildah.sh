#!/bin/bash
# -*- mode: sh -*-
# © Copyright IBM Corporation 2018, 2019
#
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build a RHEL image, using the buildah tool
# Usage
# mq-buildah.sh ARCHIVE-NAME PACKAGES

set -x
set -e

function usage {
  echo "Usage: $0 ARCHIVE-NAME PACKAGES TAG VERSION MQDevFlag"
  exit 20
}

if [ "$#" -ne 5 ]; then
  echo "ERROR: Invalid number of parameters"
  usage
fi

###############################################################################
# Setup MQ server working container
###############################################################################

# Use RHEL 7 minimal container (which doesn't include things like Python or Yum)
readonly ctr_mq=$(buildah from rhel7-minimal)
if [ -z "$ctr_mq" ]
then
  echo "ERROR: ctr_mq is empty. Check above output for errors"
  exit 50
fi

readonly mnt_mq=$(buildah mount $ctr_mq)
if [ -z "$mnt_mq" ]
then
  echo "ERROR: mnt_mq is empty. Check above output for errors"
  exit 50
fi

readonly archive=downloads/$1
readonly packages=$2
readonly tag=$3
readonly version=$4
readonly mqdev=$5

###############################################################################
# Install MQ server
###############################################################################

# Use the Yum repositories configured on the host
cp /etc/yum.repos.d/* ${mnt_mq}/etc/yum.repos.d/
# Install the packages required by MQ
yum install -y --installroot=${mnt_mq} --setopt install_weak_deps=false --setopt=tsflags=nodocs --setopt=override_install_langs=en_US.utf8 \
  bash \
  bc \
  coreutils \
  file \
  findutils \
  gawk \
  glibc-common \
  grep \
  passwd \
  procps-ng \
  sed \
  shadow-utils \
  tar \
  util-linux \
  which

groupadd --root ${mnt_mq} --system --gid 888 mqm
useradd --root ${mnt_mq} --system --uid 888 --gid mqm mqm
usermod --root ${mnt_mq} -aG root mqm
usermod --root ${mnt_mq} -aG mqm root

# Clean up cached files
yum clean --installroot=${mnt_mq} all
rm -rf ${mnt_mq}/var/cache/yum/*
rm -rf ${mnt_mq}/etc/yum.repos.d/*

# Install MQ server packages into the MQ builder image
./mq-advanced-server-rhel/install-mq-rhel.sh ${ctr_mq} "${mnt_mq}" "${archive}" "${packages}"

# Create the directory for MQ configuration files
mkdir -p ${mnt_mq}/etc/mqm
chown 888:888 ${mnt_mq}/etc/mqm

# Install the Go binaries into the image
install --mode 0750 --owner 888 --group 888 ./build/runmqserver ${mnt_mq}/usr/local/bin/
install --mode 6750 --owner 888 --group 888 ./build/chk* ${mnt_mq}/usr/local/bin/
install --mode 0750 --owner 888 --group 888 ./NOTICES.txt ${mnt_mq}/opt/mqm/licenses/notices-container.txt

###############################################################################
# Final Buildah commands
###############################################################################

if [ "$mqdev" = "TRUE" ]; then
  OSTAG="mq messaging developer"
  DISNAME="IBM MQ Advanced Server Developer Edition"
  PID="98102d16795c4263ad9ca075190a2d4d"
else
  OSTAG="mq messaging"
  DISNAME="IBM MQ Advanced Server"
  PID="4486e8c4cc9146fd9b3ce1f14a2dfc5b"
fi

buildah config \
  --port 1414/tcp \
  --port 9157/tcp \
  --os linux \
  --label architecture=x86_64 \
  --label io.openshift.tags="$OSTAG" \
  --label io.k8s.display-name="$DISNAME" \
  --label io.k8s.description="IBM MQ is messaging middleware that simplifies and accelerates the integration of diverse applications and business data across multiple platforms.  It uses message queues to facilitate the exchanges of information and offers a single messaging solution for cloud, mobile, Internet of Things (IoT) and on-premises environments." \
  --label name="${tag%:*}" \
  --label vendor="IBM" \
  --label version="$version" \
  --label release="1" \
  --label run="docker run -d -e LICENSE=accept --name ibm-mq ${tag%:*}" \
  --label summary="$DISNAME" \
  --label description="IBM MQ is messaging middleware that simplifies and accelerates the integration of diverse applications and business data across multiple platforms.  It uses message queues to facilitate the exchanges of information and offers a single messaging solution for cloud, mobile, Internet of Things (IoT) and on-premises environments." \
  --label IBM_PRODUCT_ID="$PID" \
  --label IBM_PRODUCT_NAME="$DISNAME" \
  --label IBM_PRODUCT_VERSION="$version" \
  --env AMQ_ADDITIONAL_JSON_LOG=1 \
  --env LANG=en_US.UTF-8 \
  --env LOG_FORMAT=basic \
  --entrypoint runmqserver \
  --user root \
  $ctr_mq
buildah unmount $ctr_mq
buildah commit $ctr_mq $tag

buildah rm $ctr_mq

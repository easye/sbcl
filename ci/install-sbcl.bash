#!/usr/bin/env bash

dir=/var/tmp

pushd ${dir}
release=sbcl-1.2.11-x86-64-darwin
file=${release}-binary.tar.bz2
wget http://prdownloads.sourceforge.net/sbcl/${file}
tar xfvz ${file}
cd ${release}
INSTALL_ROOT=/usr/local sh install.sh






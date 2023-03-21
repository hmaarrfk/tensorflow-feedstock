#!/bin/bash
exit 0

set -exuo pipefail

pushd tensorflow-estimator

WHEEL_DIR=${PWD}/wheel_dir
mkdir -p ${WHEEL_DIR}
bazel build tensorflow_estimator/tools/pip_package:build_pip_package
bazel-bin/tensorflow_estimator/tools/pip_package/build_pip_package ${WHEEL_DIR}
${PYTHON} -m pip install --no-deps ${WHEEL_DIR}/*.whl
bazel clean
popd

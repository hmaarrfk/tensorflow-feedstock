#!/bin/bash

set -ex

if [[ "${CI:-}" == "github_actions" ]]; then
  export CPU_COUNT=4
fi

# hmaarrfk - 2025/07/06
# Address incompatibility with newer ABSEL
# Make libprotobuf-python-headers visible for pybind11_protobuf
# These files will be deleted at the end of the build.
mkdir -p $PREFIX/include/python
cp -r $PREFIX/include/google $PREFIX/include/python/

cp ${RECIPE_DIR}/pybind11_protobuf/*.patch ${SRC_DIR}/third_party/pybind11_protobuf/.

sed -i.bak "s;@@PREFIX@@;$PREFIX;" third_party/pybind11_protobuf/0002-Add-Python-include-path.patch

export PATH="$PWD:$PATH"
export CC=$(basename $CC)
export CXX=$(basename $CXX)
export LIBDIR=$PREFIX/lib
export INCLUDEDIR=$PREFIX/include

export TF_PYTHON_VERSION=$PY_VER

# Upstream docstring for TF_SYSTEM_LIBS in:
# https://github.com/tensorflow/tensorflow/blob/v{{ version }}/third_party/systemlibs/syslibs_configure.bzl
#   * `TF_SYSTEM_LIBS`: list of third party dependencies that should use
#      the system version instead
#
# To avoid bazel installing lots of vendored (python) packages,
# we need to install these packages through meta.yaml and then
# tell bazel to use them. Note that the names don't necessarily
# match PyPI or conda, but are defined in:
# https://github.com/tensorflow/tensorflow/blob/v{{ version }}/tensorflow/workspace<i>.bzl

# Exceptions and TODOs:
# Needs a bazel build:
# com_google_absl
# Build failures in tensorflow/core/platform/s3/aws_crypto.cc
# boringssl (i.e. system openssl)
# Most importantly: Write a patch that uses system LLVM libs for sure as well as MLIR and oneDNN/mkldnn
# TODO(check):
# absl_py
# com_github_googleapis_googleapis
# com_github_googlecloudplatform_google_cloud_cpp
# Needs c++17, try on linux
#  com_googlesource_code_re2
export TF_SYSTEM_LIBS="
  astor_archive
  astunparse_archive
  boringssl
  com_github_googlecloudplatform_google_cloud_cpp
  com_github_grpc_grpc
  com_google_absl
  com_google_protobuf
  curl
  cython
  dill_archive
  flatbuffers
  gast_archive
  gif
  icu
  libjpeg_turbo
  org_sqlite
  png
  pybind11
  snappy
  zlib
  "

# do not build with MKL support
export TF_NEED_MKL=0
export BAZEL_MKL_OPT=""

mkdir -p ./bazel_output_base
export BAZEL_OPTS=""
# Set this to something as otherwise, it would include CFLAGS which itself contains a host path and this then breaks bazel's include path validation.
if [[ "${target_platform}" != *-64 ]]; then
  export CC_OPT_FLAGS="-O2"
elif [[ "${microarch_level}" == "1" ]]; then
  export CC_OPT_FLAGS="-O2 -march=nocona -mtune=haswell"
else
  export CC_OPT_FLAGS="-O2 -march=x86-64-v${microarch_level}"
fi

# Quick debug:
# cp -r ${RECIPE_DIR}/build.sh . && bazel clean && bash -x build.sh --logging=6 | tee log.txt
# Dependency graph:
# bazel query 'deps(//tensorflow/tools/lib_package:libtensorflow)' --output graph > graph.in
if [[ "${target_platform}" == osx-* ]]; then
  export LDFLAGS="${LDFLAGS} -lz -framework CoreFoundation -Xlinker -undefined -Xlinker dynamic_lookup"
else
  export LDFLAGS="${LDFLAGS} -lrt"
fi

if [[ ${cuda_compiler_version} != "None" ]]; then
    if [ ${target_platform} == "linux-aarch64" ]; then
	NVARCH=sbsa
    elif [ ${target_platform} == "linux-64" ]; then
	NVARCH=x86_64
    else
	NVARCH=${ARCH}
    fi
    export LDFLAGS="${LDFLAGS} -lcusparse"
    export GCC_HOST_COMPILER_PATH="${GCC}"
    export GCC_HOST_COMPILER_PREFIX="$(dirname ${GCC})"

    export TF_NEED_CUDA=1
    export TF_CUDA_VERSION="${cuda_compiler_version}"
    export TF_CUDNN_VERSION="${cudnn}"
    export HERMETIC_CUDA_VERSION="${cuda_compiler_version}"
    export HERMETIC_CUDNN_VERSION="${cudnn}"
    export TF_NCCL_VERSION=$(pkg-config nccl --modversion | grep -Po '\d+\.\d+')

    export LDFLAGS="${LDFLAGS//-Wl,-z,now/-Wl,-z,lazy}"

    if [[ "${cuda_compiler_version}" == 12* ]]; then
        export HERMETIC_CUDA_COMPUTE_CAPABILITIES=sm_60,sm_70,sm_75,sm_80,sm_86,sm_89,sm_90,sm_100,sm_120,compute_120
        export CUDNN_INSTALL_PATH=$PREFIX
        export NCCL_INSTALL_PATH=$PREFIX
        export CUDA_HOME="${BUILD_PREFIX}/targets/${NVARCH}-linux"
        export TF_CUDA_PATHS="${BUILD_PREFIX}/targets/${NVARCH}-linux,${PREFIX}/targets/${NVARCH}-linux"
        # XLA can only cope with a single cuda header include directory, merge both
        rsync -a ${PREFIX}/targets/${NVARCH}-linux/include/ ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/

        # Although XLA supports a non-hermetic build, it still tries to find headers in the hermetic locations.
        # We do this in the BUILD_PREFIX to not have any impact on the resulting jaxlib package.
        # Otherwise, these copied files would be included in the package.
        rm -rf ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cuda/extras/CUPTI
        cp -r ${PREFIX}/targets/${NVARCH}-linux/include ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cuda/
        cp -r ${PREFIX}/targets/${NVARCH}-linux/include ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cuda/extras/CUPTI/
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cudnn
        cp ${PREFIX}/include/cudnn*.h ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/gpus/cudnn/
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/nccl
        cp ${PREFIX}/include/nccl.h ${BUILD_PREFIX}/targets/${NVARCH}-linux/include/third_party/nccl/
        rsync -a ${PREFIX}/targets/${NVARCH}-linux/lib/ ${BUILD_PREFIX}/targets/${NVARCH}-linux/lib/
        mkdir -p ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin
        ln -sf ${BUILD_PREFIX}/bin/fatbinary ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin/fatbinary
        ln -sf ${BUILD_PREFIX}/bin/nvlink ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin/nvlink
        ln -sf ${BUILD_PREFIX}/bin/ptxas ${BUILD_PREFIX}/targets/${NVARCH}-linux/bin/ptxas

        export LOCAL_CUDA_PATH="${BUILD_PREFIX}/targets/${NVARCH}-linux"
        export LOCAL_CUDNN_PATH="${PREFIX}"
        export LOCAL_NCCL_PATH="${PREFIX}"

        # hmaarrfk -- 2023/12/30
        # This logic should be safe to keep in even when the underlying issue is resolved
        # xref: https://github.com/conda-forge/cuda-nvcc-impl-feedstock/issues/9
        if [[ -x ${BUILD_PREFIX}/nvvm/bin/cicc ]]; then
            cp ${BUILD_PREFIX}/nvvm/bin/cicc ${BUILD_PREFIX}/bin/cicc
        fi

        # Needs GCC 13+
        echo "build --define=xnn_enable_avxvnniint8=false" >> .bazelrc

    else
        echo "unsupported cuda version."
        exit 1
    fi
else
    export TF_NEED_CUDA=0
fi

gen-bazel-toolchain

if [[ "${target_platform}" == "osx-64" ]]; then
  # Tensorflow doesn't cope yet with an explicit architecture (darwin_x86_64) on osx-64 yet.
  TARGET_CPU=darwin
  # See https://conda-forge.org/docs/maintainer/knowledge_base.html#newer-c-features-with-old-sdk
  export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_AVAILABILITY"
elif [[ "${target_platform}" == "linux-aarch64" ]]; then
  TARGET_CPU=aarch64
elif [[ "${target_platform}" == "linux-64" || "${target_platform}" == "linux-x86_64" ]]; then
  TARGET_CPU=k8
fi

sed -i -e '/^build:linux --define=PREFIX=/d' .bazelrc
sed -i -e '/^build:linux --define=PROTOBUF_INCLUDE_PATH=/d' .bazelrc
sed -i -e '/^build:macos --define=PREFIX=/d' .bazelrc
sed -i -e '/^build:macos --define=PROTOBUF_INCLUDE_PATH=/d' .bazelrc
bazel_version_line=$(bazel --version 2>/dev/null || echo "")
if [[ "${bazel_version_line}" == bazel\ 8* ]]; then
  sed -i 's/--experimental_guard_against_concurrent_changes/--guard_against_concurrent_changes/g' .bazelrc
fi
# Ensure .bazelrc ends in a newline
echo "" >> .bazelrc

if [[ "${target_platform}" == "osx-arm64" ]]; then
  echo "build --config=macos_arm64" >> .bazelrc
  # See https://conda-forge.org/docs/maintainer/knowledge_base.html#newer-c-features-with-old-sdk
  export CXXFLAGS="${CXXFLAGS} -D_LIBCPP_DISABLE_AVAILABILITY"
fi
export TF_ENABLE_XLA=1
export BUILD_TARGET="//tensorflow/tools/pip_package:wheel //tensorflow:tensorflow_cc"

# Python settings
export PYTHON_BIN_PATH=${PYTHON}
export PYTHON_LIB_PATH=${SP_DIR}
export USE_DEFAULT_PYTHON_LIB_PATH=1

# additional settings
export TF_NEED_OPENCL=0
export TF_NEED_OPENCL_SYCL=0
export TF_NEED_COMPUTECPP=0
export TF_CUDA_CLANG=0
if [[ "${target_platform}" == linux-* ]]; then
  export TF_NEED_CLANG=0
fi
export TF_NEED_TENSORRT=0
export TF_NEED_ROCM=0
export TF_NEED_MPI=0
export TF_DOWNLOAD_CLANG=0
export TF_SET_ANDROID_WORKSPACE=0
export TF_CONFIGURE_IOS=0


#bazel clean --expunge
#bazel shutdown

./configure

sed -i '/repo_env=USE_PYWRAP_RULES=True/d' .bazelrc

# Remove legacy flags set by configure that conflicts with CUDA 12's multi-directory approach.
if [[ "${cuda_compiler_version}" == 12* ]]; then
    sed -i '/CUDA_TOOLKIT_PATH/d' .tf_configure.bazelrc
fi

if [[ "${build_platform}" == linux-* ]]; then
  $RECIPE_DIR/add_py_toolchain.sh
fi

if [[ "${bazel_version_line}" == bazel\ 8* ]] && ! grep -qF 'common --enable_workspace' .bazelrc; then
  echo "common --enable_workspace" >> .bazelrc
fi

if ! grep -qF 'crosstool_top=//bazel_toolchain:toolchain' .bazelrc; then
cat >> .bazelrc <<EOF
build --crosstool_top=//bazel_toolchain:toolchain
build --@local_config_cuda//cuda:override_include_cuda_libs=true
build --logging=6
build --verbose_failures
build --cpu=${TARGET_CPU}
build --local_resources=cpu=${CPU_COUNT}
EOF
fi

sed -i '/^build --define=PREFIX=/d' .bazelrc
sed -i '/^build --define=PROTOBUF_INCLUDE_PATH=/d' .bazelrc
echo "build --define=PREFIX=${PREFIX}" >> .bazelrc
echo "build --define=PROTOBUF_INCLUDE_PATH=${PREFIX}/include" >> .bazelrc

if [[ "${target_platform}" == linux-* ]] && ! grep -qF 'host_linkopt=-lsnappy' .bazelrc; then
  echo "build --host_linkopt=-Wl,--push-state" >> .bazelrc
  echo "build --host_linkopt=-Wl,--no-as-needed" >> .bazelrc
  echo "build --host_linkopt=-lsnappy" >> .bazelrc
  echo "build --host_linkopt=-Wl,--pop-state" >> .bazelrc
  echo "build --linkopt=-Wl,--push-state" >> .bazelrc
  echo "build --linkopt=-Wl,--no-as-needed" >> .bazelrc
  echo "build --linkopt=-lsnappy" >> .bazelrc
  echo "build --linkopt=-Wl,--pop-state" >> .bazelrc
fi
if [[ "${target_platform}" == linux-* ]] && ! grep -qF 'host_linkopt=-lcurl' .bazelrc; then
  echo "build --host_linkopt=-Wl,--push-state" >> .bazelrc
  echo "build --host_linkopt=-Wl,--no-as-needed" >> .bazelrc
  echo "build --host_linkopt=-lcurl" >> .bazelrc
  echo "build --host_linkopt=-Wl,--pop-state" >> .bazelrc
  echo "build --linkopt=-Wl,--push-state" >> .bazelrc
  echo "build --linkopt=-Wl,--no-as-needed" >> .bazelrc
  echo "build --linkopt=-lcurl" >> .bazelrc
  echo "build --linkopt=-Wl,--pop-state" >> .bazelrc
fi
if [[ "${target_platform}" == linux-* ]] && ! grep -qF 'host_linkopt=-labsl_vlog_config_internal' .bazelrc; then
  echo "build --host_linkopt=-Wl,--push-state" >> .bazelrc
  echo "build --host_linkopt=-Wl,--no-as-needed" >> .bazelrc
  echo "build --host_linkopt=-labsl_vlog_config_internal" >> .bazelrc
  echo "build --host_linkopt=-labsl_log_internal_conditions" >> .bazelrc
  echo "build --host_linkopt=-labsl_log_internal_check_op" >> .bazelrc
  echo "build --host_linkopt=-labsl_log_internal_message" >> .bazelrc
  echo "build --host_linkopt=-labsl_log_internal_nullguard" >> .bazelrc
  echo "build --host_linkopt=-Wl,--pop-state" >> .bazelrc
  echo "build --linkopt=-Wl,--push-state" >> .bazelrc
  echo "build --linkopt=-Wl,--no-as-needed" >> .bazelrc
  echo "build --linkopt=-labsl_vlog_config_internal" >> .bazelrc
  echo "build --linkopt=-labsl_log_internal_conditions" >> .bazelrc
  echo "build --linkopt=-labsl_log_internal_check_op" >> .bazelrc
  echo "build --linkopt=-labsl_log_internal_message" >> .bazelrc
  echo "build --linkopt=-labsl_log_internal_nullguard" >> .bazelrc
  echo "build --linkopt=-Wl,--pop-state" >> .bazelrc
fi

# Update TF lite schema with latest flatbuffers version
pushd tensorflow/compiler/mlir/lite/schema
flatc --cpp --gen-object-api schema.fbs
popd
rm -f tensorflow/lite/schema/conversion_metadata_generated.h
rm -f tensorflow/lite/experimental/acceleration/configuration/configuration_generated.h
rm -f tensorflow/lite/acceleration/configuration/configuration_generated.h
sed -ie "s;BUILD_PREFIX;${BUILD_PREFIX};g" tensorflow/tools/pip_package/build_pip_package.py

if [[ "${TF_CONDA_FETCH_ONLY:-}" == "1" ]]; then
  bazel ${BAZEL_OPTS} build --nobuild ${BUILD_TARGET}
  exit 0
fi

bazel ${BAZEL_OPTS} build ${BUILD_TARGET}

# build a whl file
mkdir -p $SRC_DIR/tensorflow_pkg
whl=$(ls bazel-bin/tensorflow/tools/pip_package/wheel_house/tensorflow*.whl)
cp_ver=$($PREFIX/bin/python -c "import sys;print(''.join(str(v) for v in sys.version_info[:2]))")
cp $whl $SRC_DIR/tensorflow_pkg/$(basename ${whl} | sed s@cp${cp_ver}@cp${PY_VER/./}@g) || true

if [[ ! -f "${SRC_DIR}/libtensorflow_cc_output.tar" ]]; then
  # Build libtensorflow(_cc)
  clib_tgz=$SRC_DIR/bazel-bin/tensorflow/tools/lib_package/clib.tar.gz
  clib_tar=$SRC_DIR/bazel-bin/tensorflow/tools/lib_package/clib.tar
  if [[ -f "$clib_tgz" ]]; then
    cp "$clib_tgz" $SRC_DIR/libtensorflow.tar.gz
  elif [[ -f "$clib_tar" ]]; then
    gzip -nc "$clib_tar" > $SRC_DIR/libtensorflow.tar.gz
  fi
  mkdir -p $SRC_DIR/libtensorflow_cc_output/lib
  shopt -s nullglob
  if [[ "${target_platform}" == osx-* ]]; then
    cc_mac=(bazel-bin/tensorflow/libtensorflow_cc.*)
    fw_mac=(bazel-bin/tensorflow/libtensorflow_framework.*)
    shopt -u nullglob
    if [[ ${#cc_mac[@]} -eq 0 || ${#fw_mac[@]} -eq 0 ]]; then
      exit 1
    fi
    cp -RP "${cc_mac[@]}" $SRC_DIR/libtensorflow_cc_output/lib/
    cp -RP "${fw_mac[@]}" $SRC_DIR/libtensorflow_cc_output/lib/
  else
    cc_so=(bazel-bin/tensorflow/libtensorflow_cc.so*)
    fw_so=(bazel-bin/tensorflow/libtensorflow_framework.so*)
    shopt -u nullglob
    if [[ ${#cc_so[@]} -eq 0 || ${#fw_so[@]} -eq 0 ]]; then
      exit 1
    fi
    cp -d "${cc_so[@]}" $SRC_DIR/libtensorflow_cc_output/lib/
    cp -d "${fw_so[@]}" $SRC_DIR/libtensorflow_cc_output/lib/
    framework_soname=$SRC_DIR/libtensorflow_cc_output/lib/libtensorflow_framework.so.2
    if [[ -e "$framework_soname" ]]; then
      cp -d "$framework_soname" $SRC_DIR/libtensorflow_cc_output/lib/libtensorflow_framework.so
    fi
  fi
  find $SRC_DIR/libtensorflow_cc_output/lib -maxdepth 1 -name 'libtensorflow*' -exec chmod u+w {} +

  mkdir -p $SRC_DIR/libtensorflow_cc_output/include/tensorflow
  rsync -r --chmod=D777,F666 --exclude '_solib*' --exclude '_virtual_includes/' --exclude 'pip_package/' --exclude 'lib_package/' --include '*/' --include '*.h' --include '*.inc' --exclude '*' bazel-bin/ $SRC_DIR/libtensorflow_cc_output/include
  rsync -r --chmod=D777,F666 --include '*/' --include '*.h' --include '*.inc' --exclude '*' tensorflow/cc $SRC_DIR/libtensorflow_cc_output/include/tensorflow/
  rsync -r --chmod=D777,F666 --include '*/' --include '*.h' --include '*.inc' --exclude '*' tensorflow/core $SRC_DIR/libtensorflow_cc_output/include/tensorflow/
  rsync -r --chmod=D777,F666 --include '*/' --include '*.h' --include '*.inc' --exclude '*' third_party/xla/third_party/tsl/ $SRC_DIR/libtensorflow_cc_output/include/
  rsync -r --chmod=D777,F666 --include '*/' --include '*' --exclude '*.cc' third_party/ $SRC_DIR/libtensorflow_cc_output/include/tensorflow/third_party/
  bazel_output_base_for_eigen=$(bazel ${BAZEL_OPTS} info output_base)
  eigen_archive_root=""
  if [[ -d "${bazel_output_base_for_eigen}/external/eigen_archive" ]]; then
    eigen_archive_root="${bazel_output_base_for_eigen}/external/eigen_archive"
  elif [[ -d bazel-work/external/eigen_archive ]]; then
    eigen_archive_root=bazel-work/external/eigen_archive
  fi
  if [[ -z "$eigen_archive_root" ]]; then
    exit 1
  fi
  rsync -r --chmod=D777,F666 --include '*/' --include '*' --exclude '*.txt' "${eigen_archive_root}/Eigen/" $SRC_DIR/libtensorflow_cc_output/include/tensorflow/third_party/Eigen/
  rsync -r --chmod=D777,F666 --include '*/' --include '*' --exclude '*.txt' "${eigen_archive_root}/unsupported/" $SRC_DIR/libtensorflow_cc_output/include/tensorflow/third_party/unsupported/
  pushd $SRC_DIR/libtensorflow_cc_output
    tar cf ../libtensorflow_cc_output.tar .
  popd
  rm -r $SRC_DIR/libtensorflow_cc_output
fi

# This was only needed for protobuf_python
rm -rf $PREFIX/include/python

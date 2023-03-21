# https://github.com/tensorflow/tensorflow/blob/master/tensorflow/tools/lib_package/README.md
exit 0
tar -C ${PREFIX} -xzf $SRC_DIR/libtensorflow.tar.gz

# Make writable so patchelf can do its magic
chmod u+w $PREFIX/lib/libtensorflow*

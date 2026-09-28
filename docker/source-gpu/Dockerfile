FROM nvidia/cuda:12.8.1-devel-ubuntu24.04 AS ffmpeg-build

ARG DEBIAN_FRONTEND=noninteractive
ARG FFMPEG_COMMIT=db69d06eeeab4f46da15030a80d539efb4503ca8
ARG NV_CODEC_HEADERS_COMMIT=e844e5b26f46bb77479f063029595293aa8f812d
ARG CUDA_ARCH=89

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential ca-certificates git nasm pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN git init /tmp/nv-codec-headers \
    && git -C /tmp/nv-codec-headers remote add origin https://github.com/FFmpeg/nv-codec-headers.git \
    && git -C /tmp/nv-codec-headers fetch --depth 1 origin "${NV_CODEC_HEADERS_COMMIT}" \
    && git -C /tmp/nv-codec-headers checkout --detach FETCH_HEAD \
    && make -C /tmp/nv-codec-headers -j"$(nproc)" \
    && make -C /tmp/nv-codec-headers install

RUN git init /tmp/ffmpeg \
    && git -C /tmp/ffmpeg remote add origin https://github.com/FFmpeg/FFmpeg.git \
    && git -C /tmp/ffmpeg fetch --depth 1 origin "${FFMPEG_COMMIT}" \
    && git -C /tmp/ffmpeg checkout --detach FETCH_HEAD \
    && cd /tmp/ffmpeg \
    && ./configure \
       --prefix=/opt/ffmpeg \
       --disable-debug \
       --disable-doc \
       --disable-ffplay \
       --disable-shared \
       --disable-autodetect \
       --disable-everything \
       --enable-static \
       --enable-nonfree \
       --enable-ffmpeg \
       --enable-ffprobe \
       --enable-avcodec \
       --enable-avdevice \
       --enable-avfilter \
       --enable-avformat \
       --enable-swresample \
       --enable-ffnvcodec \
       --enable-cuda-nvcc \
       --enable-cuvid \
       --enable-nvdec \
       --enable-nvenc \
       --enable-decoder=opus \
       --enable-decoder=vp9 \
       --enable-decoder=vp9_cuvid \
       --enable-demuxer=matroska \
       --enable-encoder=aac \
       --enable-encoder=h264_nvenc \
       --enable-filter=aformat \
       --enable-filter=aresample \
       --enable-filter=color \
       --enable-filter=format \
       --enable-filter=scale_cuda \
       --enable-filter=split \
       --enable-hwaccel=vp9_nvdec \
       --enable-indev=lavfi \
       --enable-muxer=flv \
       --enable-muxer=null \
       --enable-parser=opus \
       --enable-parser=vp9 \
       --enable-protocol=file \
       --enable-protocol=rtmp \
       --enable-protocol=tcp \
       --extra-cflags=-I/usr/local/cuda/include \
       --extra-ldflags=-L/usr/local/cuda/lib64 \
       --nvccflags="-gencode arch=compute_${CUDA_ARCH},code=sm_${CUDA_ARCH} -O2" \
    && make -j"$(nproc)" \
    && make install

FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl iproute2 procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ffmpeg-build /opt/ffmpeg/ /opt/ffmpeg/
COPY docker/source-gpu/start-publishers /usr/local/bin/start-publishers
COPY media/generated/source/glass-half-2160p.webm /opt/media/glass-half-2160p.webm

ENV PATH=/opt/ffmpeg/bin:${PATH} \
    NVIDIA_VISIBLE_DEVICES=0 \
    NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

RUN chmod 0755 /usr/local/bin/start-publishers \
    && test -s /opt/media/glass-half-2160p.webm \
    && ffmpeg -hide_banner -encoders 2>&1 | grep -q 'h264_nvenc' \
    && ffmpeg -hide_banner -filters 2>&1 | grep -q 'scale_cuda' \
    && mkdir -p /var/log/streaming

LABEL org.opencontainers.image.title="Livestreaming lab GPU source" \
      org.opencontainers.image.description="CUDA/NVDEC/NVENC live ABR contribution encoder for Kathara" \
      org.opencontainers.image.licenses="LicenseRef-FFmpeg-nonfree-local-build"

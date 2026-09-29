# Experimental media

`./labctl prepare cpu` downloads the native 3840×2160 **Glass Half** open
movie and creates a full-length, keyframe-aligned H.264 bitrate ladder at
240p, 360p, 480p, 720p, 1080p, and 2160p, plus one shared lossless audio loop.
All downloading and transcoding happen in a container; the generated files are
ignored by version control.

`./labctl prepare gpu` downloads only the native 4K VP9/Opus source. The live
GPU source creates all six H.264/AAC renditions at runtime instead of storing
them in `generated/variants/`.

Glass Half is an open movie from the Blender Foundation, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The required
attribution is written to `generated/ATTRIBUTION.txt`.

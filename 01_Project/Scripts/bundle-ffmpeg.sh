#!/bin/sh
set -eu
for tool in "${FFMPEG_EXECUTABLE:-}" /Applications/Magpie.app/Contents/Resources/ffmpeg /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    if [ -x "$tool" ]; then
        if otool -L "$tool" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/|/usr/lib/)' >/dev/null; then
            continue
        fi
        folder="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
        mkdir -p "$folder"
        /usr/bin/install -m 755 "$tool" "$folder/ffmpeg"
        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$folder/ffmpeg"
        exit 0
    fi
done
echo 'error: Set FFMPEG_EXECUTABLE to a self-contained macOS FFmpeg build with MPEG-2, PCM and MXF support.' >&2
exit 1

#!/bin/zsh
# usage: shoot.sh <outdir> <light|dark> <dm|group>
set -e
D=$1
python3 "${0:A:h}/make_html.py" "$D" "$2" "$3" >/dev/null
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
shot() { "$CH" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=3 \
  --window-size=390,$3 --screenshot="$D/$2.png" "file://$D/$1.html" >/dev/null 2>&1; }
shot body body 2600; shot header header 122; shot footer footer 86; shot cc cc 844

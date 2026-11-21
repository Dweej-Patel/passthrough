#!/usr/bin/env bash
# The same test as `ConPtyProbe emit`, from inside WSL. Run through the host:
#   ConPtyProbe host <mode> --name wsl-<mode> -- C:\Windows\System32\wsl.exe -d Ubuntu --cd <this folder> -- bash emit.sh
e=$'\033'; st="${e}\\"
printf '%s' "[[A]]${e}]52;c;aGVsbG8="$'\a'"[[B]]${e}]7501;state=working:msg=dGVzdGluZw==${st}[[C]]${e}]7501;?${st}${e}[c"
old=$(stty -g); stty raw -echo
IFS= read -r -t 2 -d '' back
stty "$old"
printf '\r\n'
printf '%s' "$back" | od -An -tx1 | tr -d ' \n' | fold -w 64 | sed 's/^/[[R]] /'
printf '\r\n[[R/]]\r\n'
printf '%s' "[[D]]${e}P1\$r0m${st}[[E]]"; printf '\r\n'
for i in $(seq -w 1 200); do
  printf 'line %s\r\n' "$i"
  [ "$i" = "100" ] && printf '%s' "${e}]7501;state=blocked:msg=bWlkZGxl${st}"
  [ $((10#$i % 20)) -eq 0 ] && sleep 0.03
done
printf '[[F]]\r\n'
sleep 0.3

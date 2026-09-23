# Licences for the prebuilt tun2socks engine

`lib/libhev-socks5-tunnel.a` is a static library built by `scripts/build-hev.sh`
from the following upstream projects, each under its own licence:

| Component | Upstream | Licence |
|---|---|---|
| hev-socks5-tunnel | https://github.com/heiher/hev-socks5-tunnel | MIT |
| hev-task-system | https://github.com/heiher/hev-task-system | MIT |
| lwIP | https://savannah.nongnu.org/projects/lwip/ | BSD-3-Clause |
| libyaml | https://github.com/yaml/libyaml | MIT |

`include/hev-main.h` is copied verbatim from hev-socks5-tunnel.

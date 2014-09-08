rpminstall
==========

rpminstall provides the ability to resolve RPM dependencies and fully install
multiple RPM packages, without reliance on any external database or index.

Written by Stuart Shelton <stuart.shelton@hp.com>, maintained by Daniele
Borsaro <daniele.borsaro@hp.com>.

Copyright 2013-2014 Hewlett-Packard Development Company, L.P.

Licensed under the MIT License (the "License"); you may not use this project
except in compliance with the License.

Installation
============

`rpmlist.sh` compares the installed RPM packages to those available in
a specified location.  This script should appear somewhere in your `${PATH}` -
the suggested location is `/usr/local/bin/`, as this script can be invoked by
any user.

`rpminstall.sh` will run `rpmlist.sh` in order to determine potential available
updates, and will then use the packages present in the specified location to
resolve the dependencies of the updates, and install all necessary pacakges in
order to upgrade the system in a dependency-consistent manner.  Since
`rpminstall.sh` will attempt to perform package installations, the suggested
installation location is `/usr/local/sbin`.

`rpminstall.sh` will take advantage of `bash-4` associative arrays, if
available.  If `bash-4` is not available, then the ability to automatically
restart upgraded running services is lost.

The package location is determined by two parameters - the '`--host`' option
specifies a host (defaulting to `rpmrepo.localdomain`) which is expected to be
running an `rsync` server, whilst the '`--location`' option specifies the rsync
repo on this host which should be connected to.

An example `rsyncd.conf` might read:

```
pid file = /var/run/rsyncd.pid
use chroot = no
uid = nobody
gid = nobody

log file = /var/log/rsync.log
transfer logging = no

read only = yes
list = yes

[vendor]
        path = /srv/vendor
	uid = root
	comment = Vendor RPMs
	hosts allow = 10.0.0.0/8, 127.0.0.0/8
```

... for a local network of 10.0.0.0/255.0.0.0.  The directory layout beneath
`/srv/vendor` is intended to resemble the following:

```
/srv/vendor/centos/5.9		-> /path/to/CentOS/5.9/
/srv/vendor/centos/5.10		-> /path/to/CentOS/5.10/

/srv/vendor/centos/current	-> 5.10/

/srv/vendor/centos/addons	-> current/addons/x86_64/RPMS/
/srv/vendor/centos/centosplus	-> current/centosplus/x86_64/RPMS/
/srv/vendor/centos/contrib	-> current/contrib/x86_64/RPMS/
/srv/vendor/centos/extras	-> current/extras/x86_64/RPMS/
/srv/vendor/centos/fasttrack	-> current/fasttrack/x86_64/RPMS/
/srv/vendor/centos/os		-> current/os/x86_64/CentOS/
/srv/vendor/centos/updates	-> current/updates/x86_64/RPMS/
```

... for a 64-bit CentOS 5.10 target.  This layout allows for multiple vendors
and multiple distributions to be targetted simply by updating a symlink (or for
multiple rsync repos to contain different symlinks to a shared storage
location - although rsync may need to be configured to follow out-of-repo symlinks).

`rpminstall` should, in theory, work with any RPM-based distribution, but it has
only been tested with CentOS and Red Hat 4.x and 5.x.  The 6.x distributions
will be able to be made to work, but will likely require different/additional
package-specific hints.  Patches to add this compatibility are welcome.


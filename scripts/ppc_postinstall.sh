#!/bin/bash
#
# PPC YaST2 postinstall script
#


while read line; do
	case "$line" in
		*MacRISC*)    MACHINE="mac";;
		*CHRP*)       MACHINE="chrp";;
		*PReP*)       MACHINE="prep" ;;
		*iSeries*)    MACHINE="iseries";;
	esac
done < /proc/cpuinfo

if test $MACHINE = iseries ; then

for i in `fdisk -l | grep PReP | cut -d\  -f1`
do
	j=`echo $i | sed 's/\([0-9]\)/ \1/'`
	/sbin/activate $j
done

sed '/^.*mingetty.*$/d' /etc/inittab > /etc/inittab.tmp
diff /etc/inittab /etc/inittab.tmp &>/dev/null || mv -v /etc/inittab.tmp /etc/inittab

#echo "1:12345:respawn:/bin/login console" >> /etc/inittab
cat >> /etc/inittab <<-EOF


# iSeries virtual console:
1:2345:respawn:/sbin/mingetty --noclear tty1

# to allow only root to log in on the console, use this:
# 1:2345:respawn:/sbin/sulogin /dev/console

# to disable authentication on the console, use this:
# y:2345:respawn:/bin/bash

EOF

if grep -q tty10 /etc/syslog.conf; then
echo "changing syslog.conf"
sed '/.*tty10.*/d; /.*xconsole.*/d' /etc/syslog.conf > /etc/syslog.conf.tmp
diff /etc/syslog.conf /etc/syslog.conf.tmp &>/dev/null || mv -v /etc/syslog.conf.tmp /etc/syslog.conf
fi

sed -e '/\/dev\/ram/d' \
    -e '\/dev\/viocd0[[:space:]]*om/d' \
    -e 's@^.*floppy.*@/dev/viocd0     /cdrom                    auto            ro,noauto,user,exec 0   0@' \
    < /etc/fstab > /etc/fstab.neu ; mv /etc/fstab.neu /etc/fstab

( echo "SuSE Linux on iSeries -- the spicy solution!"
  echo "Have a lot of fun..."
) > /etc/motd


fi # iseries


# p690/p670 has a hvc console
grep -q "console=hvc" < /proc/cmdline && {

sed '/^.*mingetty.*$/d' /etc/inittab > /etc/inittab.tmp
diff /etc/inittab /etc/inittab.tmp &>/dev/null || mv -v /etc/inittab.tmp /etc/inittab

cat >> /etc/inittab <<-EOF


# p690 virtual console:
#V0:12345:respawn:/sbin/agetty -L 9600 hvc0 vt320

# to allow only root to log in on the console, use this:
# 1:2345:respawn:/sbin/sulogin /dev/console

# to disable authentication on the console, use this:
# y:2345:respawn:/bin/bash

EOF
echo "hvc0" >> /etc/securetty
echo "hvc/0" >> /etc/securetty


}
# p690
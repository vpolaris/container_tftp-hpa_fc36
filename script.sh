#!/bin/bash
cd /usr/bin 
for i in $(/usr/sbin/busybox --list); 
do
  /usr/sbin/busybox ln -s /usr/sbin/busybox $i
done
ls /usr/sbin/
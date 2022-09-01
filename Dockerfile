ARG sysroot=/mnt/sysroot
ARG TFTP_USERNAME="nobody"
ARG TFTP_DIRECTORY="/srv/tftp"
ARG TFTP_ADDRESS="0.0.0.0:69"
ARG TFTP_OPTIONS="--secure -c"

FROM fedora:36 as builder
ARG sysroot
ARG TFTP_USERNAME
ARG TFTP_DIRECTORY
ARG TFTP_ADDRESS
ARG TFTP_OPTIONS

ARG DISTVERSION=36
ARG DNFOPTION="--setopt=install_weak_deps=False --nodocs"

#update builder
RUN dnf makecache && dnf -y update && dnf -y install gettext 

#install system
RUN dnf -y --installroot=${sysroot} ${DNFOPTION} --releasever ${DISTVERSION} install glibc setup shadow-utils

RUN yes | rm -f ${sysroot}/dev/null \
    &&mknod -m 600 ${sysroot}/dev/initctl p \
    && mknod -m 666 ${sysroot}/dev/full c 1 7 \
    && mknod -m 666 ${sysroot}/dev/null c 1 3 \
    && mknod -m 666 ${sysroot}/dev/ptmx c 5 2 \
    && mknod -m 666 ${sysroot}/dev/random c 1 8 \
    && mknod -m 666 ${sysroot}/dev/tty c 5 0 \
    && mknod -m 666 ${sysroot}/dev/tty0 c 4 0 \
    && mknod -m 666 ${sysroot}/dev/urandom c 1 9


#dhcpd prerequisites
RUN dnf -y --installroot=${sysroot} ${DNFOPTION} --releasever ${DISTVERSION} install --noautoremove busybox tftp
RUN dnf -y --installroot=${sysroot} ${DNFOPTION} --releasever ${DISTVERSION} install --downloadonly --downloaddir=./ initscripts tftp-server ipxe-bootimgs

COPY ./script.sh "${sysroot}/script.sh"

RUN chmod +u+x "${sysroot}/script.sh" && chroot ${sysroot} /script.sh && rm "${sysroot}/script.sh"

RUN ARCH="$(uname -m)" \
    && TFPTPRPM="$(ls tftp-server*${ARCH}.rpm)" \
    && TFPTVERSION=$(sed -e "s/tftp-server-\(.*\)\.${ARCH}.rpm/\1/" <<< $TFPTPRPM) \
    && rpm -ivh --root=${sysroot}  --nodeps --excludedocs ${TFPTPRPM} \
    && printf ${TFPTVERSION} > ${sysroot}/tftp.version


RUN cat << EOF | tee ${sysroot}/etc/sysconfig/network \
    NETWORKING=yes \
    HOSTNAME=localhost.localdomain\
    EOF
 
 COPY "./tftp.template" "${sysroot}/root/tftp.template"
 COPY "./tftp.service" "${sysroot}/etc/rc.d/init.d/tftp.service"
 COPY "./entrypoint.sh"  "${sysroot}/bin/entrypoint.sh"


RUN chmod u+x  "${sysroot}/etc/rc.d/init.d/tftp.service" "${sysroot}/bin/entrypoint.sh" 

ENV TINI_VERSION v0.19.0
ADD "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini" "${sysroot}/tini"
RUN chmod +x "${sysroot}/tini"

RUN cp "/usr/bin/envsubst" "${sysroot}/usr/bin/envsubst" \
    && envsubst '${TFTP_USERNAME} ${TFTP_DIRECTORY} ${TFTP_ADDRESS} ${TFTP_OPTIONS}'< "${sysroot}/root/tftp.template" > "${sysroot}/etc/default/tftpd-hpa" \
    && if [ $(getent passwd ${TFTP_USERNAME}>/dev/null;echo $?) -eq 0 ];then \
         echo 'user already created' \
       else \ 
         chroot "${sysroot}" adduser -S -D -s /sbin/nologin -h "${TFTP_DIRECTORY}" "${TFTP_USERNAME}" \
       ;fi \
    && mkdir -p "${sysroot}/${TFTP_DIRECTORY}" \
    && chroot ${sysroot} chown ${TFTP_USERNAME} "${TFTP_DIRECTORY}" \
    && chmod 775 "${sysroot}/${TFTP_DIRECTORY}" 
 
#clean up
RUN dnf -y --installroot=${sysroot} ${DNFOPTION} --releasever ${DISTVERSION} remove shadow-utils

RUN ARCH="$(uname -m)" \
    && INITRPM="$(ls initscripts*${ARCH}.rpm)" \
    && rpm -ivh --root=${sysroot}  --nodeps --excludedocs ${INITRPM}
 
RUN IMGRPM="$(ls ipxe-bootimgs*.rpm)" \
    && rpm -ivh --root="${sysroot}/tmp"  --nodeps --excludedocs ${IMGRPM} \
    && mkdir -p ${sysroot}/${TFTP_DIRECTORY}/{efi32,efi64,install,kernel,snp} \
    && mv "${sysroot}/tmp/usr/share/ipxe/ipxe-i386.efi" "${sysroot}/${TFTP_DIRECTORY}/efi32" \
    && mv "${sysroot}/tmp/usr/share/ipxe/ipxe-x86_64.efi" "${sysroot}/${TFTP_DIRECTORY}/efi64" \
    && mv ${sysroot}/tmp/usr/share/ipxe/{ipxe.iso,ipxe.usb,ipxe.dsk} ${sysroot}/${TFTP_DIRECTORY}/install \
    && mv "${sysroot}/tmp/usr/share/ipxe/ipxe.lkrn" "${sysroot}/${TFTP_DIRECTORY}/kernel" \
    && mv "${sysroot}/tmp/usr/share/ipxe/ipxe-snponly-x86_64.efi" "${sysroot}/${TFTP_DIRECTORY}/snp" \
    && mv "${sysroot}/tmp/usr/share/ipxe/undionly.kpxe" "${sysroot}/${TFTP_DIRECTORY}/undionly.kpxe"
    
  
RUN dnf -y --installroot=${sysroot} ${DNFOPTION} --releasever ${DISTVERSION}  autoremove \    
    && dnf -y --installroot=${sysroot} ${DNFOPTION} --releasever ${DISTVERSION}  clean all \
    && rm -rf ${sysroot}/usr/{{lib,share}/locale,{lib,lib64}/gconv,bin/localedef,sbin/build-locale-archive} \
#  docs and man pages       
    && rm -rf ${sysroot}/usr/share/{man,doc,info,gnome/help} \
#  purge log files
    && rm -f ${sysroot}/var/log/*|| exit 0 \
#  cracklib
    && rm -rf ${sysroot}/usr/share/cracklib \
#  i18n
    && rm -rf ${sysroot}/usr/share/i18n \
#  packaging
    && rm -rf ${sysroot}/var/cache/dnf/ \
    && mkdir -p --mode=0755 ${sysroot}/var/cache/dnf/ \
    && rm -f ${sysroot}//var/lib/dnf/history.* \
    && rm -f ${sysroot}//usr/lib/sysimage/rpm/* \
#  sln
    && rm -rf ${sysroot}/sbin/sln \
#  ldconfig
    && rm -rf ${sysroot}/etc/ld.so.cache ${sysroot}/var/cache/ldconfig \
    && mkdir -p --mode=0755 ${sysroot}/var/cache/ldconfig

FROM scratch 
ARG sysroot
ARG TFTP_USERNAME
ARG TFTP_DIRECTORY
ARG TFTP_ADDRESS
ARG TFTP_OPTIONS
COPY --from=builder ${sysroot} /
ENV DISTTAG=f36container FGC=f36 FBR=f36 container=podman
ENV DISTRIB_ID fedora
ENV DISTRIB_RELEASE 36
ENV PLATFORM_ID "platform:f36"
ENV DISTRIB_DESCRIPTION "Fedora 36 Container"
ENV TZ UTC
ENV LANG C.UTF-8
ENV TERM xterm
  
ENV TFTP_USERNAME="${TFTP_USERNAME}"
ENV TFTP_DIRECTORY="${TFTP_DIRECTORY}"
ENV TFTP_ADDRESS="${TFTP_ADDRESS}"
ENV TFTP_OPTIONS="${TFTP_OPTIONS}"

# 69 udp for TFTP port
EXPOSE 69/udp 
ENTRYPOINT ["./tini", "--", "/bin/entrypoint.sh"]
CMD ["start"]

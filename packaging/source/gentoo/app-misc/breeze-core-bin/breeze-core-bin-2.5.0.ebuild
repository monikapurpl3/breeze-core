# Copyright 2026 Breeze Core contributors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit systemd

DESCRIPTION="Self-hosted, LAN-first control for Midea air conditioners (prebuilt bundle)"
HOMEPAGE="https://github.com/monikapurpl3/breeze-core"

# Prebuilt self-contained bundle from the GitHub release. A pure source ebuild
# isn't feasible: the Python deps (msmart-ng, brotli-asgi) are not in ::gentoo
# and ebuilds must not touch the network at build time. If you want a source
# install, follow docs/INSTALL.md (venv layout) instead.
_TARBALL_ARCH_amd64="glibc-amd64"
_TARBALL_ARCH_arm64="glibc-arm64"
SRC_URI="
	amd64? ( ${HOMEPAGE}/releases/download/v${PV}/breeze-core-${PV}-linux-glibc-amd64.tar.gz )
	arm64? ( ${HOMEPAGE}/releases/download/v${PV}/breeze-core-${PV}-linux-glibc-arm64.tar.gz )
"
S="${WORKDIR}"

LICENSE="AGPL-3"
SLOT="0"
KEYWORDS="~amd64 ~arm64"
RESTRICT="strip"          # PyInstaller bootloader must not be re-stripped
QA_PREBUILT="usr/lib/breeze-core/*"

RDEPEND="
	acct-group/breeze
	acct-user/breeze
"

src_install() {
	local d
	d="$(echo breeze-core-${PV}-linux-glibc-*)"

	insinto /usr/lib/breeze-core
	doins -r "${d}"/breeze-core/.
	fperms 0755 /usr/lib/breeze-core/breeze-core
	dosym ../lib/breeze-core/breeze-core /usr/bin/breeze-core

	# systemd unit + OpenRC init (Gentoo runs both worlds).
	systemd_dounit "${d}"/breeze-core.service
	newinitd "${d}"/breeze-core.initd breeze-core

	insinto /etc/breeze-core
	insopts -m0640 -o root -g breeze
	doins "${d}"/breeze-core.env

	keepdir /etc/breeze-core
	fowners breeze:breeze /etc/breeze-core
	fperms 0750 /etc/breeze-core

	dodoc "${d}"/README.md
}

pkg_postinst() {
	elog "1. Pair your units:   breeze-core pair   (as root)"
	elog "2. Set BREEZE_HOST in /etc/breeze-core/breeze-core.env"
	elog "3. systemd: systemctl enable --now breeze-core"
	elog "   OpenRC:  rc-update add breeze-core default && rc-service breeze-core start"
}

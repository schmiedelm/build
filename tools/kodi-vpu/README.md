# Kodi 22 mit VPU (Hantro G1/G2) auf imx8mp – Bauanleitung und Stand

Stand 12.11.2026. Jede Angabe trägt einen Status: **gemessen** (Messung auf dem
Board), **im Quelltext gelesen**, **abgeleitet** (nicht geprüft), **offen**.

## 1. Warum das nötig ist

- Die Hantro G1 (H.264) und G2 (HEVC) sind *stateless* Decoder. ffmpeg spricht sie
  über die Hwaccel `v4l2request`; Debian-ffmpeg (libavcodec61, 7.1.5) und Debian-Kodi 21.2
  haben sie nicht (**gemessen**: Interrupt-Zähler wuchsen nicht).
- Kodi 22 hängt an ffmpeg 9.0.2 und nutzt den `DRMPRIME`-Decoder mit jeder Hwaccel,
  die `AV_PIX_FMT_DRM_PRIME` liefert (**abgeleitet** aus xbmc PR 25467). Gebaut mit
  eigenem ffmpeg (v4l2request-Patch) dekodiert Kodi per VPU (**gemessen**, siehe 5).

## 2. Zutaten

| Teil | Quelle | Prüfsumme |
|---|---|---|
| ffmpeg 9.0.2 | `https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz` | sha256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` (**gemessen**, passt zum LibreELEC-Pin) |
| Patch v4l2-request | LibreELEC `packages/multimedia/ffmpeg/patches/v4l2-request/0001-v4l2-request.patch`; Raw-URL **abgeleitet**: `https://raw.githubusercontent.com/LibreELEC/LibreELEC.tv/master/packages/multimedia/ffmpeg/patches/v4l2-request/0001-v4l2-request.patch` (ungeprüft, Verzeichnis `https://github.com/LibreELEC/LibreELEC.tv/tree/master/packages/multimedia/ffmpeg/patches/v4l2-request` ist belegt) | sha256 der verwendeten Datei: `afd04c202c27081c355d8d34b58a52c4141de26433007e27ed6e0d2093d10d3c` (**gemessen**) |
| Kodi 22.0rc2-Piers | `https://github.com/xbmc/xbmc/archive/refs/tags/22.0rc2-Piers.tar.gz` | keine erfasst, **offen** |

Nicht angewendet: `0002-v4l2-request-vc1.patch`, `0003-vc1-mpeg12-backports.patch`
(auf dem Board nicht benutzt; nur `0001` nachweislich). Der Patch
`postproc/0001-postproc.patch` ist für ffmpeg 9 nicht nötig: 9.0.2 enthält
libpostproc nicht (**abgeleitet**).

Der Patch wird im ffmpeg-Quellverzeichnis mit `patch -p1 --batch -i <datei>` angewendet
(**gemessen**; ein `--dry-run` taugt für diesen Mehr-Commit-Patch nicht).

## 3. Build auf dem Board (der funktionierende Weg, **gemessen**)

Board: arm64, Debian trixie, 4×A53, ~3,5 GiB RAM. Gesamtdauer Kodi 224 min bei `-j2`.

1. Pakete: `deb-src` in den APT-Quellen aktivieren, `apt-get build-dep kodi`,
   zusätzlich `apt-get install -y bison meson ninja-build`. **Offen:** ob darüber hinaus
   Pakete nötig waren; Fehler beim Konfigurieren nennen das fehlende Paket.
2. ffmpeg (Prefix `/opt/kodi-ffmpeg`, **gemessen** aus `config.log`):
   ```
   ./configure --prefix=/opt/kodi-ffmpeg --enable-shared --disable-static --enable-gpl \
     --enable-libdrm --enable-libudev --enable-v4l2-request --enable-v4l2-m2m \
     --disable-doc --disable-debug
   make -j2 && make install
   ```
3. Kodi: konfiguriert und gebaut im Verzeichnis `/root/kodibuild/build`. Die genaue
   Kommandozeile liegt **nicht** vor, nur der Inhalt von `CMakeCache.txt` (**gemessen**):
   `CMAKE_BUILD_TYPE=Release`, `CMAKE_INSTALL_PREFIX=/opt/kodi-22`, `CORE_PLATFORM_NAME=gbm`,
   `APP_RENDER_SYSTEM=gles`, `ENABLE_INTERNAL_FFMPEG=OFF`, `FFMPEG_PATH=/opt/kodi-ffmpeg`,
   `ENABLE_VAAPI=OFF`, `ENABLE_VDPAU=OFF`, `ENABLE_DVDCSS=OFF`, `ENABLE_UDEV=ON`,
   `ENABLE_OPTICAL=ON`, `ENABLE_AIRTUNES=ON`, `ENABLE_ALSA/BLURAY/CEC/LCMS2/PIPEWIRE/PULSEAUDIO=AUTO`.
   Auf **ON** (selbst gebaut, laden beim Build aus dem Netz): `ENABLE_INTERNAL_CROSSGUID`,
   `_LIBDVD`, `_SWIG`, `_DATE`, `_KISSFFT`, `_TZDATA`. Auf **OFF** (Systembibliotheken):
   `_ASS _BLURAY _CEC _CURL _DAV1D _EXIV2 _FFMPEG _FLATBUFFERS _FMT _FSTRCMP _GTEST _LCMS2
   _LIBMICROHTTPD _LZO2 _MARIADBCLIENT _NFS _NLOHMANNJSON _PCRE2 _SPDLOG _TAGLIB _UDFREAD _XSLT`.
   Ein Eintrag `DISABLE_FFMPEG_SOURCE_PLUGINS` (überspringt libpostproc) ist **offen**: aus
   der Erinnerung nicht belegt, im Cache nicht abgefragt.
   **Erste Aufgabe morgen auf dem Board** (liefert die fehlende Rezeptur):
   ```
   grep -E ':(BOOL|STRING|PATH|UNINITIALIZED)=' /root/kodibuild/build/CMakeCache.txt \
     | grep -E 'ENABLE_|DISABLE_|CORE_|APP_|FFMPEG|CMAKE_BUILD_TYPE|CMAKE_INSTALL_PREFIX' > /root/kodi-cache.txt
   ```
   und die Datei auf den Host holen. Es fehlt außerdem die Befehlszeile mit
   `-DENABLE_INTERNAL_SWIG=ON` (SWIG aus Debian war zu alt); `ENABLE_INTERNAL_*` mit
   `UNINITIALIZED` kamen vermutlich aus der Kommandozeile, das ist **abgeleitet**.
4. `cmake --build . -j2`, `cmake --install . --prefix /opt/kodi-22`.
   Kodi findet das ffmpeg über RPATH (**gemessen**: `ldd` zeigt `libavcodec.so.63`
   aus `/opt/kodi-ffmpeg/lib` ohne `LD_LIBRARY_PATH`); die Binärdatei heißt `kodi-gbm`
   (`/opt/kodi-22/lib/kodi/kodi-gbm`), nicht `kodi.bin`.

## 4. Pflichteinstellung: DRM-PRIME-Decoder einschalten

Ohne diese Einstellung dekodiert Kodi in Software (**gemessen**: G1/G2-Zähler wuchsen nicht,
Log: `CDVDVideoCodecFFmpeg`, keine DRMPRIME-Zeile). Ursache (**im Quelltext gelesen**):
`DVDVideoCodecDRMPRIME.cpp:105-108` liefert `nullptr`, wenn `videoplayer.useprimedecoder` aus ist;
`:152-168` verlangt zusätzlich `videoplayer.useprimedecoderforhw`. Default im Quelltext:
`system/settings/linux.xml:176-180` auf `false`.

Gesetzt wurde in `~/.kodi/userdata/guisettings.xml`:
`<setting id="videoplayer.useprimedecoder">true</setting>` (`useprimedecoderforhw` stand schon auf `true`).
Dauerhaft im Build: `cross/patches/0001-settings-useprimedecoder-default-true.patch` setzt den Default
in `system/settings/linux.xml` auf `true`. `build-in-container.sh` wendet den Patch beim Entpacken an.
Ein Profil mit gespeichertem `false` bleibt bei `false`. Dort die Zeile in `guisettings.xml` löschen.
Board-Messung mit dem Patch-Build **offen**. Mit gesetzter Einstellung (Cross-Build, 13.11.2026, **gemessen**):
H.264 720p: G1 0 → 1362, G2 unverändert.

## 4a. Hänger beim Umschalten der Bildwiederholrate

Kodi schaltet ab Werk beim Start und Stopp der Wiedergabe die HDMI-Bildwiederholrate um
(`videoplayer.adjustrefreshrate` = 2), z. B. auf 23,976 Hz. Danach hing das Board (**gemessen**, 14.11.2026):
- `kodi-gbm` im Zustand D in `rpm_resume`, mehrere kworker in `clk_prepare_lock`.
- `kblockd` und der eMMC-Flush hängen mit. Neue Befehle auf der Konsole starten nicht mehr.
- Speicher frei (`MemAvailable` 3,4 GB), dmesg ohne Meldung.
- Letzte Kodi-Zeilen: `Display resolution ADJUST : 1920x1080 @ 23.976 Hz`, `OnLostDisplay`.

Ursache im Kernel (**gemessen**, SysRq-w beim Stresstest, 14.11.2026): ABBA-Deadlock.
- `clk_core_set_rate_nolock()` (`drivers/clk/clk.c`) hält `clk_prepare_lock` und ruft `clk_pm_runtime_get()`
  für den Provider von `hdmi_pclk` auf, die HDMI-PHY.
- Der Runtime-Suspend der PHY (`phy-fsl-samsung-hdmi.c`) ruft `clk_disable_unprepare()` und braucht dieselbe Sperre.
- Läuft der Suspend gerade im pm-kworker, warten beide aufeinander. Das Zeitfenster ist klein, der Hänger selten.

Fix-Kandidat: `patch/kernel/archive/imx8m-7.3/0012-phy-freescale-fsl-samsung-hdmi-fix-deadlock-with-clk.patch`
(Runtime-PM nur `clk_disable()`/`clk_enable()`). Stacks: `modetest` in `clk_set_rate` (aus `lcdif_crtc_atomic_enable`)
→ `rpm_resume`; kworker `pm_runtime_work` in `fsl_samsung_hdmi_phy_suspend` → `clk_unprepare` → `clk_prepare_lock`.
`hdmi-mode-stress.sh -v <datei>` (ohne Kodi) löst den Hänger ohne Patch beim 1.–2. Wechsel aus (**gemessen**).
Stresstest mit Patch **offen**. Hinweis: Nach dem Hänger fehlen frisch kopierte Dateien (eMMC-Flush blockiert),
vor jedem Test `sync`.

Workaround (**gemessen**: 3 Starts ohne Hänger): `videoplayer.adjustrefreshrate` = 0.
`cross/patches/0002-settings-adjustrefreshrate-default-off.patch` setzt diesen Default im Build.
Ein Profil mit gespeichertem Wert behält den Wert. Dort die Zeile in `guisettings.xml` löschen.

## 4b. Ton: Rauschen über den TLV320AIC3204 (Kopfhörerausgang)

Kodi wählt `AE_FMT_S24NE4` (ALSA `S24_LE`). Ergebnis: lautes Rauschen. `speaker-test` (**gemessen**, 14.11.2026):
`S16_LE` und `S32_LE` sauber, `S24_LE` Rauschen, je bei 44,1 und 48 kHz.
Ursache (**im Quelltext gelesen**): Der Codec ist Takt-Master und nimmt `params_physical_width` (32-bit-Slots),
SAI nimmt `params_width` (24-bit-Slots). Fix: `patch/kernel/archive/imx8m-7.3/0013-ASoC-fsl-asoc-card-exclude-S20_3LE-and-S24_LE-for-tlv.patch`
schließt `S20_3LE` und `S24_LE` aus, Kodi nimmt dann `S32_LE`. Test mit Patch **offen**.

## 4c. Ton über HDMI

Kodi sah nur die Karte `tq-mba8mp-ras314` (TLV320AIC3204). Die HDMI-Karte `audio-hdmi` (DT `sound-hdmi`, AUD2HTX,
PAI) fehlte, weil drei Kernel-Optionen aus waren (**im Quelltext gelesen**): `CONFIG_SND_SOC_IMX_HDMI` (wählt
`CONFIG_SND_SOC_FSL_AUD2HTX` mit), `CONFIG_DRM_DW_HDMI_GP_AUDIO`. Beide als Modul in `config/kernel/linux-imx8m-{edge,current}.config`
ergänzt (Position wie `savedefconfig`). Board (**gemessen**, 15.11.2026): Karte `audio-hdmi` vorhanden, Ton über
HDMI in Kodi nach Umstellen des Audioausgabegeräts ok.
Ab `kodi-vpu` tq8: `/etc/alsa/conf.d/50-kodi-vpu-hdmi.conf` setzt `audiohdmi` als ALSA-Standardgerät (`plug` auf
`hw:CARD=audiohdmi,DEV=0`). Board (**gemessen**): Kodi stellte trotzdem von `Default` auf
`sysdefault:CARD=tqmba8mpras314` um. Ursache (**im Quelltext gelesen**, `CActiveAESink::ValidateOuputDevice`): `Default`
hat keinen Treiber, Kodi nimmt das erste Gerät mit „default“ im Namen; `@` passt nicht. Ab tq9:
`cross/patches/0005-settings-audiodevice-default-alsa.patch` setzt den Standard auf `ALSA:@` (**offen** auf dem Board).
Vorhandene Profile: einmal „Default (audio-hdmi …)“ in den Audioeinstellungen wählen.

## 5. Messung (unabhängiger Beweis über den Kernel)

```
grep -E '38300000|38310000' /proc/interrupts      # G1 = 38300000 (H.264), G2 = 38310000 (HEVC)
export LD_LIBRARY_PATH=/opt/kodi-ffmpeg/lib KODI_HOME=/opt/kodi-22/share/kodi
timeout 60 /opt/kodi-22/lib/kodi/kodi-gbm --windowing=gbm --standalone <datei>
grep -E '38300000|38310000' /proc/interrupts
```
Ergebnis (**gemessen**): H.264 720p x264: G1 215 → 1576; HEVC-Clip: G2 100 → 125 (+25), G1 unverändert.
Log: `CDVDVideoCodecDRMPRIME::Open - using decoder ...`. Bild des Films war sichtbar (GL-Rendern).
`rc=124` ist hier normal (`timeout` beendet Kodi). Kodi läuft auf der Konsole, ohne Desktop.

## 6. Pakete und Image-Integration

`pack-debs.sh` packt `/opt/kodi-ffmpeg` und `/opt/kodi-22` in `kodi-ffmpeg-v4l2request` und `kodi-vpu`
(Abhängigkeiten per `dpkg-shlibdeps`). Es läuft auf dem Board (nativer Build) oder im Cross-Container:
`cross/cross-build.sh <workdir> debs` → `<workdir>/out/debs/` (**gemessen**: Pakete gebaut, Inhalt root:root).
Version `tq2`: ffmpeg mit RUNPATH, Kodi mit den Patches aus `cross/patches/`.

Image (nur lokal, `userpatches/` ist in `.gitignore`): `userpatches/customize-image.sh` (Funktion `InstallKodiVpu`)
installiert bei trixie/arm64 für `mba8mpxl-ras314` alle Pakete aus `userpatches/overlay/kodi-vpu/` per apt und
prüft `kodi-gbm --version` und aktiviert `kodi-vpu.service`. Ohne Pakete im Verzeichnis überspringt es den Schritt.
Image-Build mit tq2-Paketen (**gemessen**, 14.11.2026): Installation ok, 2 Videos mit Ton abgespielt.

Autostart (ab `kodi-vpu` tq3): Das Paket liefert `kodi-vpu.service` (tty1, Benutzer `kodi`, PAM-Sitzung) und legt
per `postinst` den Systembenutzer `kodi` an (Home `/var/lib/kodi`, Gruppen video, render, input, audio).
Das Paket aktiviert die Unit nicht. Test im arm64-Container (**gemessen**): Installation, Benutzer, `systemctl enable` ok.
Auf dem Board **offen**.

HDMI-CEC (ab `kodi-vpu` tq4): Kodi mit libcec 7 (Debian, mit Linux-CEC-Adapter für `/dev/cec0`). Dafür braucht der
Cross-Container `libp8-platform-dev:arm64` (`libcec.pc` verlangt `p8-platform`), sonst `CEC enabled: No`.
Kernel (**im Quelltext gelesen**): `CONFIG_DRM_DW_HDMI_CEC=m`, Pad `HDMI_CEC` im RAS314-DT gemuxt, kein `disable_cec`.
`/dev/cec*` gehört der Gruppe `video` (udev).
Board (**gemessen**, 14.11.2026): `/dev/cec0` vorhanden, aber `cec-ctl --playback -S` zeigt `Physical Address: f.f.f.f`,
keine logische Adresse, leere Topologie. Ursache (**im Quelltext gelesen**): LCDIF hängt die HDMI-Bridge mit
`DRM_BRIDGE_ATTACH_NO_CONNECTOR` an; dw-hdmi registriert den CEC-Notifier nur im eigenen Connector.
Fix: `patch/kernel/archive/imx8m-7.3/0014-drm-bridge-dw-hdmi-set-CEC-physical-address-with-bri.patch`
(Notifier beim Attach, Adresse aus der EDID in `edid_read`; ab Fassung 2 zusätzlich `hpd_notify`: nach einem Hotplug
liest ein Delayed Work die EDID neu, weil Kodi als DRM-Master nicht neu abfragt. **Gemessen**: ohne das blieb die PA
nach einem TV-Eingangswechsel auf `f.f.f.f`, Kodi bekam keine Adresse und keine Tasten). Board (**gemessen**): PA `3.0.0.0`, LA 4, Tasten der
TV-Fernbedienung kommen an. Der Vestel-Fernseher meldet sich als LA 14, nicht 0.
Senden sporadisch mit sofortigem `Tx, Error` (Initiator-Fehler). `cec-pad-test.sh` (Pad zur Laufzeit, je 30 Nachrichten,
**gemessen**): `0x30` 3 Fehler, `0xb0` (Schmitt-Trigger) 0, `0x1f0` 0. Fix: DT-Patch Schmitt-Trigger am Pad `HDMI_CEC`
nur für RAS314 (`imx8m-6.18/0012-…`, `imx8m-7.3/0015-…`). Auf current fehlt der Notifier-Patch 0014 weiterhin.
Kodi (**gemessen**, 14.11.2026): Tasten kommen in Kodi an, wenn libcec LA 4 (Playback) hat. Dafür nötig:
`device_type` Playback (Standard Recording scheitert öfter) und `activate_source`/`wake_devices` aus. Sonst wartet
Kodi in `WaitReady()` endlos auf einen TV unter LA 0 und verwirft alle Tasten (Vestel-TV sitzt auf LA 14).
Ab `kodi-vpu` tq7: `cross/patches/0003-peripherals-cec-defaults-playback-no-wake.patch` (Playback, keine Geräte wecken)
und `0004-cec-waitready-timeout.patch` (`WaitReady()` gibt nach etwa 10 s auf). Damit bleibt `activate_source` an:
Kodi meldet sich beim Start als aktive Quelle. Ohne das schickte der TV nach dem Booten keine Tasten (**gemessen**,
erst nach TV-Eingangswechsel per `SET_STREAM_PATH`). tq5/tq6 hatten `activate_source` aus.
Offen: Adressvergabe unzuverlässig (von 4 Kodi-Starts 1× LA 4). Poll an die eigene Adresse endet oft mit
`Tx, Error` statt NACK; der CEC-Kern überspringt die Adresse dann (`cec_config_log_addr`).
Workaround (`kodi-vpu` tq6): `kodi-vpu-cec-watch.service` (von `kodi-vpu.service` per `Wants` gestartet) startet Kodi
neu, solange die Maske `0x8000` ist und die PA gültig; höchstens 5 Neustarts in Folge, Prüfung alle 60 s.
Variablen: `KODI_CEC_MAX_RESTARTS`, `KODI_CEC_SETTLE`, `KODI_CEC_INTERVAL`. Logik mit Attrappen getestet (**gemessen**),
auf dem Board **offen**. Ursache der Sendefehler: Messung am CEC-Pin mit Oszilloskop geplant (**offen**).
Pad-Durchlauf `cec-pad-sweep.sh` (je 10 Anmeldungen, **gemessen**): mit allen brauchbaren Werten 10/10 belegt,
aber 65–111 `Error` (Schmitt-Werte 65–72, ohne Schmitt 91–95, langsame Flanke 111). Pull-down `0x1b0`: 0/10,
nur `Error`. Also meldet `ERROR_INIT`, dass die Leitung nach dem Freigeben noch low ist. Verdacht (**abgeleitet**):
zu schwacher Pull-up auf der SoC-Seite bzw. Pegelwandler verlangsamt den Anstieg. Nächster Schritt: CEC-Pfad im
Schaltplan, Oszilloskop auf SoC- und HDMI-Seite.
Oszilloskop (**gemessen**, 16.11.2026, TDS2022C, 20 µs/Sample, Messpunkt HDMI-Stecker Pin 13, `tools/ALL0003/`): Pegel High 3,33 V,
Low ≈ 0,04 V. Anstieg 0 → 2,4–2,9 V innerhalb eines Samples (< 20 µs), 3,16 V nach ≈ 60 µs; Abfall < 20 µs (Grenze laut
Spezifikation: Anstieg 250 µs). Timing nach Spezifikation: Startbit 3,72/0,82 ms, Bit 0 1,54/0,90 ms, Bit 1 0,62/1,82 ms.
Rahmen dekodiert: `0100 0100 EOM=1 ACK=1` = Poll von LA 4 an LA 4, nicht bestätigt (NACK = Adresse frei).
7,36 ms später derselbe Header erneut (3 Bitzeiten = Wartezeit für eine Wiederholung). Deutung (**abgeleitet**): Der
Kern hat wiederholt, also meldete der Treiber für einen elektrisch sauberen NACK-Rahmen einen Fehler statt NACK.
Damit ist der Verdacht „langsamer Anstieg“ an diesem Messpunkt widerlegt. Nächster Schritt: SoC- und HDMI-Seite
gleichzeitig (CH1/CH2), Kernel-Status je Rahmen mitschreiben (`cec`-Debug), Zeitpunkt des `Tx, Error` zuordnen.
Treiber (**im Quelltext gelesen**, `dw-hdmi-cec.c`, Hardirq): `CEC_STAT_ERROR_INIT` wird vor `DONE` und `NACK` geprüft.
Setzt der Controller bei einem NACK zusätzlich `ERROR_INIT`, meldet der Treiber `ERROR`. Prüfung: `cec-stat-debug/`
(Treiber mit `trace_printk` des rohen Status, Bau auf dem Board gegen die Header aus `output/debs/`; Bau unter qemu
**gemessen**). Board-Trace (**gemessen**, 16.11.2026, `cec-pad-test.sh` an LA 14, ≈ 61 Nachrichten):
- Kein `0x14`: NACK und ERROR_INIT kommen nie zusammen. Die Vermutung „Treiber verwechselt NACK“ ist widerlegt.
- ≈ 2/3 der Nachrichten: 4 Versuche mit `stat 0x04` (NACK) im Abstand von ≈ 34 ms (= Header gesendet, nicht
  bestätigt). Der TV bestätigt LA 14 derzeit nicht; deshalb 30/30 Fehler bei jedem Pad-Wert.
- ≈ 1/3 der Nachrichten: `stat 0x11` (DONE + ERROR_INIT) 0,07–7,5 ms nach dem Start, alle 4 Versuche innerhalb
  von ≈ 1 ms. Das ist kürzer als ein Startbit (4,5 ms): Der Controller bricht im Startbit ab. Am HDMI-Stecker kann
  so ein Abbruch nur als verkürzter Low-Puls sichtbar sein.
- Deutung (**abgeleitet**): Der Controller liest während des eigenen Startbits einen falschen Pegel. Verdacht auf
  den Eingangspfad SoC-seitig (Pegelwandler/Schutzbaustein). Nächster Schritt: SoC-Pin messen, Trigger auf
  Low-Puls kürzer als 3,6 ms.
- Mit eingeschaltetem TV (**gemessen**): TV jetzt unter LA 0 (vorher LA 14), Board LA 4. Nach einem
  HDMI-Quellenwechsel nur noch LA 15 (Unregistered), die Fernbedienung geht nicht. Kette (**abgeleitet**): sofortige
  `0x11`-Abbrüche bei den Polls → der Kern überspringt die Adressen → Unregistered → der TV schickt keine Tasten.
- Wächter für Messungen abschalten: `systemctl mask --runtime --now kodi-vpu-cec-watch.service`.
- Trace mit Quellenwechseln (**gemessen**, `tools/ALL0003/cec-hpd.trace`): 52× DONE, 73× EOM, 12× NACK, 278× `0x11`.
  Die `0x11` kommen in Schüben; im Schub scheitert jede Nachricht sofort (Polls, Kodi-Broadcasts, `cec-ctl`).
  Ein Schub endet nach dem nächsten Empfang (EOM). Im EOM-Zweig schreibt der Treiber `HDMI_CEC_LOCK = 0`.
  Verdacht (**abgeleitet**): Ein Rahmen sperrt den Empfangspuffer ohne EOM (z. B. Follower-Fehler, `ERROR_FOLL`
  ist maskiert); solange `LOCK` gesetzt ist, bricht jedes Senden ab. Prüfung: `cec-stat-debug` Fassung 2
  (`lock` im Trace, `ERROR_FOLL` sichtbar, Parameter `fix_lock`).
- Fassung 2 auf dem Board (**gemessen**, `cec-a.trace`, `cec-b.trace`): `lock` beim Senden immer 0, `lock 1` nur bei
  EOM, kein `ERROR_FOLL`, `fix_lock` ohne Wirkung (158× `0x11`). Verdacht „Empfangssperre“ widerlegt.
  Abstand `0x11` → nächstes EOM: Median 65 ms, aber nicht immer < 400 ms. Rahmen zwischen anderen Geräten sind
  im Trace unsichtbar; „Bus belegt“ bleibt möglich (**offen**).
- Fassung 3: Parameter `retry_ms`/`retry_max`. Bei `ERROR_INIT` wartet der IRQ-Thread `retry_ms` und setzt
  `CEC_CTRL_START` erneut (wie der ursprüngliche Treiber von 2017), statt sofort `ERROR` zu melden. Bau unter qemu
  **gemessen**, Board **offen**.
- Beobachtung Nutzer (16.11.2026): Ab- und Anstecken des HDMI-Kabels bringt die Fernbedienung zurück. Deutung
  (**abgeleitet**): Hotplug → neue Anmeldung mit Polls; gelingt sie, LA 4. Auf LA 15 bleibt das Board bis zum
  nächsten Hotplug.
- Fassung 3 mit `retry_ms=10` (**gemessen**, 16.11.2026): 65 Versuche mit Neustarts, alle enden mit OK (`0x1`) oder
  NACK (`0x4`), keiner mit Error. 1–12 Neustarts (10–120 ms), am häufigsten 4 (≈ 40 ms). Der Zustand ist also kurz.
  Trace `cec-c.trace`: 2069× `0x11` vor dem ersten Neustart (vor `retry_ms=10`), danach 298× `0x11` und 299 Neustarts,
  kein `0x11` ohne Neustart. Nach jedem Quellenwechsel/Umstecken LA 4 (`0x0010`) und Fernbedienung ok.
  Ergebnis: verzögerter Neustart nach `ERROR_INIT` behebt die Ausfälle.
- Patch: `imx8m-6.18/0013-…` und `imx8m-7.3/0016-drm-bridge-dw-hdmi-cec-restart-transmit-after-ERROR_INIT.patch`
  (10 ms, höchstens 50 Neustarts je Versuch). Mainline 7.4-rc3 ohne Korrektur. Bau unter qemu mit `W=1` ohne Warnung
  (**gemessen**). Im Image **offen**. Danach `kodi-vpu-cec-watch` und `cross/patches/0004` (WaitReady) neu bewerten.
```
mkdir -p userpatches/overlay/kodi-vpu && cp <workdir>/out/debs/*.deb userpatches/overlay/kodi-vpu/
```

Erster Hänger aus dem Paket (12.11.2026): Ursache sehr wahrscheinlich der HDMI-Deadlock aus Abschnitt 4a (**abgeleitet**).

## 7. Cross-Compile (gebaut am 12.11.2026, auf dem Board **gemessen**)

Echter Cross-Build ohne Emulation: Docker `debian:trixie` (amd64) mit Multiarch `arm64`,
`crossbuild-essential-arm64` und `apt-get build-dep -a arm64 kodi` (**gemessen**: löst vollständig auf).
Rezeptur wie Abschnitt 3. Dateien in `cross/`:

- `Dockerfile`: Umgebung. Zusätzlich die Systembibliotheken aus Abschnitt 3 (Debian-build-dep
  enthält z. B. `libexiv2-dev` nicht). Debians `libav*-dev:arm64` wird entfernt.
- `build-in-container.sh`: Schritte `ffmpeg`, `tools`, `kodi`, `all`.
- `cross-build.sh <workdir> [schritt]`: baut das Image und startet den Container.

Ablauf:
```
mkdir -p ~/_work/kodi-cross/src && cd ~/_work/kodi-cross/src
# die drei Dateien aus Abschnitt 2 hierher laden, Prüfsummen vergleichen
tools/kodi-vpu/cross/cross-build.sh ~/_work/kodi-cross all
```
Ergebnis: `<workdir>/out/opt/kodi-ffmpeg` und `<workdir>/out/opt/kodi-22`.

Unterschiede zum nativen Build (**gemessen**):
- ffmpeg: `--enable-cross-compile --arch=aarch64 --target-os=linux --cross-prefix=aarch64-linux-gnu-
  --pkg-config=aarch64-linux-gnu-pkg-config --extra-ldflags=-Wl,-rpath,/opt/kodi-ffmpeg/lib`. Hwaccels: `drm`, `v4l2request` (+ vaapi/vdpau, ungenutzt).
- Host-Werkzeuge: SWIG und JsonSchemaBuilder über `NATIVEPREFIX/share/Toolchain-Native.cmake`,
  TexturePacker vorab nativ, an Kodi per `-DWITH_TEXTUREPACKER`.
- `-DCMAKE_INSTALL_RPATH=/opt/kodi-ffmpeg/lib` ist Pflicht. Ohne diese Option fehlt im Cross-Build die RUNPATH.
- Dauer auf dem Host (16 Kerne): Kodi ca. 10 min (aus Datei-Zeitstempeln, **nicht genau gemessen**).

Prüfung unter qemu-binfmt im Container (**gemessen**): `kodi-gbm --version` startet ohne `LD_LIBRARY_PATH`.
ffmpeg bekommt `--extra-ldflags=-Wl,-rpath,/opt/kodi-ffmpeg/lib`. Damit startet die ffmpeg-CLI ohne
`LD_LIBRARY_PATH` (**gemessen**, `ffmpeg -hwaccels`). Der native Build aus Abschnitt 3 hat diese Option nicht.

Nächster Schritt: `out/opt/*` auf das Board kopieren und gegen Abschnitt 5 messen.
Ein Binary ohne diese Messung gilt als nicht bestätigt.

Randbedingungen aus der Zusammenarbeit: Downloads für das Board per `curl`-Befehl auf dem Board
formulieren; volle Image-Builds startet der Nutzer; Zugriff auf das Board nur durch den Nutzer.
Für spätere Distributionen: Laufzeitbibliotheken stammen aus trixie; je Zielrelease neu bauen.
Ablage der Pakete: nur lokal (`userpatches/overlay/kodi-vpu/`, Abschnitt 6). Kein GitHub-Release, keine Extension.

## 8. ToDo (Stand 15.11.2026)

Offen aus dem bisherigen Stand:
- CEC-Sendefehler: Ursache gefunden (Abschnitt 6), Patch `dw-hdmi-cec` restart after ERROR_INIT. Im Image testen,
  danach Wächter-Dienst entfernen und Upstream-PR vorbereiten.
- HDMI-Stresstest `hdmi-mode-stress.sh` mit Patch 0012; danach Kodi-Patch 0002 (Bildwiederholrate) prüfen.
- Upstream-PRs vorbereiten: Kernel 0012 (HDMI-PHY), 0013 (Audioformat), 0014 (CEC-Adresse), 0015 (CEC-Pad),
  Kernel-Config HDMI-Audio. 0014 und 0015 auch für `imx8m-6.18` klären.

Erledigt:
- Fernbedienung geht direkt nach dem Booten mit `kodi-vpu` tq7 (bestätigt 15.11.2026).

Neu geplant:
- Fernsehen über Kodi (Zattoo), läuft ohne DRM über die VPU, Widevine offen (Abschnitt 10): PVR-Add-on bzw. Plugin für Kodi 22 finden und für arm64 bauen. Zu klären:
  DRM (Widevine über `inputstream.adaptive` auf arm64), Hardware-Dekodierung der Streams über die VPU.
- Spielen über Kodi, Emulatoren: RetroPlayer mit `game.libretro`-Cores als Binär-Add-ons (Cross-Build gegen die
  Kodi-22-Header), Controller-Zuordnung.
- Spielen, Moonlight (Steam-Streaming vom PC), Paket gebaut, Board-Test offen (Abschnitt 9): Moonlight-Client für arm64 mit Dekodierung über die VPU
  (H.264/HEVC, v4l2-request), Start aus Kodi heraus (Kodi beenden bzw. DRM-Master übergeben), Controller.

Recherche 15.11.2026 (Status: **im Quelltext gelesen** bzw. **abgeleitet**, nichts auf dem Board geprüft):
- Allgemein: Debian-Add-ons (`kodi-pvr-zattoo`, `kodi-game-libretro*`, `kodi-inputstream-adaptive`) passen zur
  Kodi-21-API und laden nicht in Kodi 22. Alle Binär-Add-ons gegen Kodi 22 bauen, z. B. im Cross-Container
  mit `cmake/addons` und `ADDONS_TO_BUILD` (**abgeleitet**).
- Zattoo: `pvr.zattoo` 22.2.3, Zweig `Piers` in `https://github.com/rbuehlma/pvr.zattoo`. Benötigt
  `inputstream.adaptive` (Zweig `Piers`, aktiv) und `script.module.inputstreamhelper`. Einstellung „DRM Level“:
  Auto = L3 unter Linux, „Disable DRM“ = -1. Erster Test ohne Widevine mit „Disable DRM“.
  Widevine arm64: seit 07/2026 enthält Chrome für arm64 Linux eine native `linux_arm64`-CDM (Presse, offiziell
  nicht bestätigt). Ob `inputstreamhelper` diese CDM nutzt, ist **offen**. Bei L3 entschlüsselt
  `inputstream.adaptive`, Kodi dekodiert selbst, also über den vorhandenen DRMPRIME/v4l2request-Pfad (**abgeleitet**).
  Abo-Umfang (Kanäle, HD) ist Sache des Zattoo-Vertrags.
- Emulatoren: `game.libretro` und `repo-binary-addons` haben Zweige `Piers` (aktiv, 11/2026). Kerne einzeln
  bauen (alle Kerne dauern Stunden). Zusätzlich `peripheral.joystick` für Controller. Kandidaten für 4×A53 mit
  etnaviv-GLES: nestopia/fceumm, snes9x, genesis_plus_gx, mgba, pcsx_rearmed (**abgeleitet**, Leistung **offen**).
- Moonlight: `moonlight-qt` (master aktiv). `ffmpeg.cpp` nimmt jede Hwaccel mit `AV_PIX_FMT_DRM_PRIME`
  (Kommentar verweist auf die v4l2request-Serie) und nutzt dann den `DrmRenderer` → gegen `/opt/kodi-ffmpeg`
  bauen. LCDIF (imx8mp) hat nur eine Ebene ohne NV12 (`lcdif_kms.c`), also Anzeige über EGL/etnaviv statt
  Overlay-Ebene (**abgeleitet**). Bau ohne X: `CONFIG+=embedded`, SDL mit KMSDRM, Qt `eglfs_kms`. Start: Kodi
  stoppen, Moonlight starten, danach Kodi neu starten (wie LibreELEC-Flatpak-Add-on). PC-Seite: Sunshine
  (oder Apollo) statt NVIDIA GameStream.

## 9. Moonlight (Spiele-Streaming vom PC)

Ziel: Moonlight startet aus Kodi, dekodiert per VPU und gibt danach Kodi zurück. Host auf dem PC: Sunshine.

Quelle: `https://github.com/moonlight-stream/moonlight-qt/releases/download/v6.2.0/MoonlightSrc-6.2.0.tar.gz`,
sha256 `217afac54e4f8734f3d97b32cb8c8b46b677e87f25b77c945343dd06f359e189` (**gemessen**; enthält die Submodule).
Nach `<workdir>/src/` legen.

Bau im Cross-Container (**gemessen**, 15.11.2026), braucht `/opt/kodi-ffmpeg` aus dem Schritt `ffmpeg`:
```
tools/kodi-vpu/cross/cross-build.sh ~/_work/kodi-cross moonlight
tools/kodi-vpu/cross/cross-build.sh ~/_work/kodi-cross moonlight-deb
```
- `aarch64-linux-gnu-qmake6` (Debian-Qt 6.8.2), `CONFIG+=embedded`, `PREFIX=/opt/moonlight`, RUNPATH `/opt/kodi-ffmpeg/lib`.
- Aktiv: `HAVE_DRM`, `HAVE_DRM_MASTER_HOOKS`, `HAVE_EGL`, `EMBEDDED_BUILD`. VAAPI/VDPAU/X11/Wayland sind mitgebaut
  (Bibliotheken aus dem Kodi-build-dep), auf dem Board ungenutzt.
- `pack-moonlight-deb.sh` → `moonlight-vpu_6.2.0-tq3_arm64.deb`. Inhalt: `/opt/moonlight`, `/usr/bin/moonlight-vpu`
  (Qt `eglfs_kms`), `moonlight-vpu.service` (`Conflicts=kodi-vpu.service`, startet Kodi per `ExecStopPost` neu),
  `/etc/default/moonlight-vpu` (z. B. `AUDIODEV`), sudoers-Regel für `kodi`, Kodi-Add-on `script.moonlight-vpu`.
- Test im arm64-Container unter qemu (**gemessen**): Installation zusammen mit tq7 ok, `ldd` ohne Lücken
  (libavcodec aus `/opt/kodi-ffmpeg`), `visudo -c` ok, `moonlight --help` startet.

Board (**gemessen**, 15.11.2026): tq1 brach nach 3 s mit SIGABRT ab (Journal leer: Moonlight loggt über einen
eigenen Thread, die Zeilen gehen beim Abbruch verloren). Qt 6.8.2 eglfs_kms nimmt ohne Konfiguration die erste
DRM-Karte (`devices.first()`, **im Quelltext gelesen**). tq2: `moonlight-vpu` wählt die Karte mit Connector und setzt
`QT_QPA_EGLFS_KMS_CONFIG` (`hwcursor` aus). Mit tq2 ist die Moonlight-Oberfläche auf dem TV sichtbar.
Koppeln mit Sunshine (Linux-PC) und Videowiedergabe ok (**gemessen**). Ton erst nach `SDL_AUDIODRIVER=alsa`,
`AUDIODEV=plughw:CARD=audiohdmi,DEV=0` (Standard war die TLV320-Karte); ab tq3 Vorgabe in `/etc/default/moonlight-vpu`.
VPU (**gemessen**, 15.11.2026): G1 (H.264) 52567 → 53341 → 54374 während des Streams, G2 unverändert (5499).
Moonlight dekodiert H.264 über die VPU. HEVC (G2) noch **offen**: Codec in den Moonlight-Einstellungen auf HEVC stellen.

Auf dem Board (**offen**):
1. `apt install ./moonlight-vpu_6.2.0-tq3_arm64.deb`. Image: Paket liegt in `userpatches/overlay/kodi-vpu/`;
   `InstallKodiVpu` installiert es mit und prüft `moonlight --help` (qemu-Test im Container **gemessen**, rc 0).
2. Ohne Kodi testen: `systemctl start moonlight-vpu.service`, Log: `journalctl -u moonlight-vpu -f`.
3. PC: Sunshine installieren; Moonlight zeigt beim Koppeln eine PIN, diese im Sunshine-Webinterface eingeben.
4. VPU prüfen: `grep -E '38300000|38310000' /proc/interrupts` vor und während des Streams (H.264 → G1, HEVC → G2).
   Statistik-Overlay in Moonlight: Strg+Alt+Shift+S.
5. In Kodi: Add-ons → Meine Add-ons → Moonlight aktivieren und starten. Nach dem Beenden muss Kodi zurückkommen.

Risiken (**abgeleitet**): LCDIF hat keine NV12-Ebene; Moonlight muss über EGL rendern (wie Kodi). Ton: SDL nimmt
das ALSA-Standardgerät; falls stumm, `AUDIODEV` in `/etc/default/moonlight-vpu` setzen.

## 10. Fernsehen: Zattoo

Ziel: Live-TV von Zattoo in Kodi, Dekodierung über die VPU.

Quellen (sha256 **gemessen**), nach `<workdir>/src/`:

| Datei | URL | sha256 |
|---|---|---|
| `inputstream.adaptive-22.3.24-Piers.tar.gz` | `https://github.com/xbmc/inputstream.adaptive/archive/refs/tags/22.3.24-Piers.tar.gz` | `374403df391a6a6053667653dc9e032622da4ccdebc908c8ec1a3853b51e17c1` |
| `pvr.zattoo-22.2.3-Piers.tar.gz` | `https://github.com/rbuehlma/pvr.zattoo/archive/refs/tags/22.2.3-Piers.tar.gz` | `0fb9f133124efa1e19b38fb7748e371295ed2d74c38b1b0ba907321a927a0a60` |
| `script.module.inputstreamhelper-0.8.6.zip` | `https://mirrors.kodi.tv/addons/piers/script.module.inputstreamhelper/script.module.inputstreamhelper-0.8.6.zip` | `1571610fb4019530f2bde22e40cabc05e2f42e42cb149083e4fa2ba8442821b2` |

Bau im Cross-Container (**gemessen**, 15.11.2026):
```
tools/kodi-vpu/cross/cross-build.sh ~/_work/kodi-cross addons
tools/kodi-vpu/cross/cross-build.sh ~/_work/kodi-cross addons-deb
```
- Kodis `cmake/addons` mit eigenen Definitionen (`ADDONS` in `build-in-container.sh`) und `ADDON_SRC_PREFIX`.
- Die Rezepte `sqlite3`/`tinyxml2` von pvr.zattoo werden entfernt: `configure` ohne `--host` baut für den Host.
  Stattdessen Debians arm64-Bibliotheken.
- Das Buildsystem installiert nach `ADDON_DEPENDS_PATH`; der Schritt kopiert die Add-on-Verzeichnisse nach
  `/opt/kodi-addons`.
- `pack-addon-debs.sh`: je Add-on ein Paket `kodi-vpu-<id>` unter `/opt/kodi-22`:
  `kodi-vpu-inputstream-adaptive`, `kodi-vpu-pvr-zattoo`, `kodi-vpu-script-module-inputstreamhelper` (all).
- Test im arm64-Container unter qemu (**gemessen**): Installation mit tq8 ok, `ldd` ohne Lücken. API-Versionen aus
  den Kodi-22-Headern (z. B. `kodi.binary.instance.pvr` 9.2.0).

Widevine (**im Quelltext gelesen**): `inputstreamhelper` 0.8.6 holt die arm64-CDM aus einem ChromeOS-Recovery-Image
(`CHROMEOS_RECOVERY_ARM64_BNAMES`). Großer Download, Platz unter `/var/lib/kodi` nötig.

Auf dem Board (**offen**):
1. Die drei Pakete installieren.
2. Kodi: Add-ons → Meine Add-ons: „InputStream Adaptive“, „InputStream Helper“ und „Zattoo PVR Client“ aktivieren.
3. Zattoo-Einstellungen: Zugangsdaten, Anbieter, zuerst „DRM Level“ = „Disable DRM“.
Board (**gemessen**, 15.11.2026): erster Start ohne Zugangsdaten: „EPG-DB: Can't open database“ (Verzeichnis
`addon_data/pvr.zattoo` fehlte noch). Nach dem Speichern der Zugangsdaten: „pvr.zattoo returned bad status
"Not implemented" during instance creation“. Nach einem Kodi-Neustart behoben: Zattoo läuft (**gemessen**).
VPU (**gemessen**, ohne DRM): G1 3523 → 4024 in 10 s (≈ 50/s, H.264 mit 50 Hz), G2 0;
Log `CDVDVideoCodecDRMPRIME::Open - using decoder H.264`. Widevine **offen**.
4. Sender öffnen; VPU über `/proc/interrupts` prüfen, Log `/var/lib/kodi/.kodi/temp/kodi.log` (`DRMPRIME`).
5. Danach Widevine über „InputStream Helper“ installieren und „DRM Level“ = Auto testen.

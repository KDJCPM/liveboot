#!/usr/bin/env bash
# 01-lay-rootfs.sh —— 把 Frame 的 rootfs 原样铺进我们自己的 ext4 镜像
# 用法: sudo scripts/host/01-lay-rootfs.sh <frame rootfs 分区镜像> <rootfs.img> <大小,如 8G>
#
# 原则：**只做“换文件系统”这一件事**。不改 fstab、不删 boot/modules、不清理引导残留、
#       不做任何 chroot 注入 —— 保证 rootfs.img 内容与原镜像一致。
#
# 关键点：
#   * Frame 的 rootfs 分区是 btrfs，必须用 subvolid=5 挂到顶层才能同时看到根子卷和平级的
#     @var/@home 子卷。
#   * 目标镜像尺寸自适应：先量出源用量，目标不足时自动放大。
#   * 铺完删掉 5 GB 的源分区镜像，给 runner 腾地方。
set -euo pipefail
log()  { printf '[%s] %s\n' "${0##*/}" "$*"; }
warn() { printf '[%s] 警告: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "${0##*/}" "$*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || die "需要 root"
SRC="${1:?用法: 01-lay-rootfs.sh <frame rootfs 镜像> <rootfs.img> <size>}"
IMG="${2:?}"
SIZE="${3:-8G}"
MOUNT_SRC=/mnt/frame-src
MOUNT_DST=/mnt/rootfs
SRC_DIR="$(cd "$(dirname "$SRC")" && pwd)"
ROOT_REL="$(cat "$SRC_DIR/frame-src-root" 2>/dev/null || echo '.')"
EXTRA_FILE="$SRC_DIR/frame-src-extra"

mkdir -p "$MOUNT_SRC" "$MOUNT_DST"
umount "$MOUNT_SRC" 2>/dev/null || true
umount "$MOUNT_DST" 2>/dev/null || true

# 1) 挂载 Frame 源分区（btrfs → subvolid=5 顶层；其它 → 自动识别）
modprobe btrfs 2>/dev/null || true
FSTYPE="$(blkid -o value -s TYPE "$SRC" 2>/dev/null || true)"
log "源分区 $SRC: fstype=${FSTYPE:-未知}"
if [[ "$FSTYPE" == "btrfs" ]]; then
  mount -o loop,ro,subvolid=5 "$SRC" "$MOUNT_SRC" || die "btrfs 挂载失败（subvolid=5）"
else
  mount -o loop,ro "$SRC" "$MOUNT_SRC" || die "挂载 Frame rootfs 失败（未知文件系统）"
fi
trap 'umount "$MOUNT_SRC" 2>/dev/null || true' EXIT
[[ -d "$MOUNT_SRC/$ROOT_REL" ]] || die "根子树 $ROOT_REL 不存在（底包结构变了）"
SRC_ROOT="$MOUNT_SRC/$ROOT_REL"
log "根子树: $ROOT_REL"

# 2) 决定「哪些平级子卷需要额外并入」（避免重复计入尺寸）
MERGE_LIST=()
if [[ -s "$EXTRA_FILE" ]]; then
  while IFS=$'\t' read -r s d; do
    [[ -n "$s" && -n "$d" ]] || continue
    [[ -d "$MOUNT_SRC/$s" ]] || { warn "子卷 $s 不存在，跳过"; continue; }
    if [[ -d "$MOUNT_SRC/$ROOT_REL/$d" && -n "$(ls -A "$MOUNT_SRC/$ROOT_REL/$d" 2>/dev/null)" ]]; then
      log "子卷 $s 随根子树一起拷贝即可（/$d 在根子树里已有内容），不再单独并入"
      continue
    fi
    MERGE_LIST+=("${s}"$'\t'"${d}")
  done < "$EXTRA_FILE"
fi
log "需要额外并入的子卷: ${#MERGE_LIST[@]} 个"

# 3) 量用量 → 目标镜像尺寸自适应（源 + 1.5 GB 余量，且不小于调用方给的下限）
need_mb="$(du -sm --exclude=proc --exclude=sys --exclude=dev --exclude=run --exclude=tmp "$SRC_ROOT" 2>/dev/null | cut -f1)"
for e in "${MERGE_LIST[@]:-}"; do
  [[ -n "$e" ]] || continue
  s="${e%%$'\t'*}"
  extra_mb="$(du -sm "$MOUNT_SRC/$s" 2>/dev/null | cut -f1 || echo 0)"
  need_mb=$(( need_mb + ${extra_mb:-0} ))
done
need_mb=$(( need_mb + 1536 ))
_sz="${SIZE^^}"; _unit="${_sz: -1}"; _num="${_sz%?}"
case "$_unit" in
  G) want_mb=$(( ${_num%.*} * 1024 ));;
  M) want_mb=$(( ${_num%.*} ));;
  *) warn "无法解析尺寸 $SIZE（只认 G/M 后缀），按源用量决定"; want_mb=0;;
esac
[[ "$want_mb" -gt 0 ]] || want_mb=0
use_mb=$(( need_mb > want_mb ? need_mb : want_mb ))
log "源用量 ${need_mb} MiB（含余量），请求 ${want_mb} MiB → 期望创建 ${use_mb} MiB"

# 磁盘护栏
avail_mb="$(df -Pm "$SRC_DIR" | awk 'NR==2{print $4}')"
src_mb=$(( $(stat -c %s "$SRC") / 1048576 ))
max_mb=$(( avail_mb + src_mb - 1024 ))
log "磁盘: 可用 ${avail_mb} MiB + 源 ${src_mb} MiB → 目标上限 ${max_mb} MiB"
if [[ "$use_mb" -gt "$max_mb" ]]; then
  warn "请求 ${use_mb} MiB 超过上限，压到 ${max_mb} MiB（内容可能装不下，随后会 ENOSPC）"
  use_mb="$max_mb"
fi
[[ "$use_mb" -ge "$need_mb" ]] || die "盘不够：内容需要 ${need_mb} MiB，但最多只能建 ${use_mb} MiB"

# 4) 建目标 ext4
log "创建 ext4 镜像 $IMG ($(( use_mb / 1024 )) GiB)"
rm -f "$IMG"; truncate -s "${use_mb}M" "$IMG"
mkfs.ext4 -q -F -L rootfs "$IMG" || die "mkfs.ext4 失败"
mount -o loop "$IMG" "$MOUNT_DST" || die "挂载新镜像失败"

# 5) rsync 根子树（保留权限/硬链接/xattr/ACL）
#    btrfs 专有 xattr 在 ext4 上必然 EOPNOTSUPP → 只容忍这一类错误。
log "rsync Frame userspace → 我们的镜像"
RSYNC_LOG="$SRC_DIR/lay-rsync.log"
set +e
rsync -aHAX --numeric-ids --info=progress2 \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
  --exclude='/tmp/*' \
  "$SRC_ROOT/" "$MOUNT_DST/" 2>"$RSYNC_LOG"
rc="$?"
set -e
if [[ "$rc" -ne 0 ]]; then
  others="$(grep -E '^rsync:' "$RSYNC_LOG" 2>/dev/null \
    | grep -vE 'lsetxattr\(.*\) failed: Operation not supported' | head -10 || true)"
  if [[ -n "$others" ]]; then
    printf '%s\n' "$others" | sed 's/^/    /' >&2
    tail -20 "$RSYNC_LOG" | sed 's/^/    /' >&2
    die "rsync 失败（rc=$rc）：见上面的错误"
  fi
  dropped="$(grep -cE 'lsetxattr\(.*\) failed: Operation not supported' "$RSYNC_LOG" 2>/dev/null || echo 0)"
  warn "rsync rc=$rc：只丢了 $dropped 个 btrfs 专有 xattr（ext4 不支持，无害），内容已拷完，继续"
fi

# 6) 平级子卷并入对应目录（Frame 布局下通常为空）
for e in "${MERGE_LIST[@]:-}"; do
  [[ -n "$e" ]] || continue
  s="${e%%$'\t'*}"; d="${e##*$'\t'}"
  log "并入子卷 $s → /$d"
  mkdir -p "$MOUNT_DST/$d"
  rsync -aHAX --numeric-ids --info=progress2 "$MOUNT_SRC/$s/" "$MOUNT_DST/$d/" \
    || warn "子卷 $s 并入侵失败（继续）"
done

# 7) 用量核对
log "目标用量：$(du -sh "$MOUNT_DST" 2>/dev/null | cut -f1) / 已用 $(df -h "$MOUNT_DST" | tail -1 | awk '{print $3" / "$2}')"

sync
umount "$MOUNT_DST"; umount "$MOUNT_SRC"; trap - EXIT
rm -f "$SRC" && log "已删除源分区镜像 $SRC（释放空间）"
df -h "$SRC_DIR" | tail -1 | sed "s/^/    磁盘: /"
log "已铺好: $IMG"

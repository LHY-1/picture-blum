// ============================================================
// PhotoGridView.swift
// 照片网格选择器：挑选要播放的照片
//
// 内存策略（针对低内存的老设备）：
//   - 缩略图走 ThumbnailCache（NSCache，有上限）
//   - 每格是独立的 View，各自持有 @State，只有变化的格子重绘
//   - LazyVGrid 只渲染可见区域，划出屏幕的格子状态自动释放
//
// 兼容：iOS 14.0+
// ============================================================

import SwiftUI
import Photos

struct PhotoGridView: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: SlideShowViewModel

    @State private var selectedIds: Set<String> = []
    /// 记着上一次开网格时的勾选，避免「播放后重开网格全要重选」
    @State private var preselected = false
    /// 各相册的照片 id 集合（相册级勾选用），打开时算一次
    @State private var albumIdSets: [String: Set<String>] = [:]

    private let columns = [
        GridItem(.adaptive(minimum: 80), spacing: 2)
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 相册级勾选：整册选 / 整册取消
                if !viewModel.library.albums.isEmpty {
                    albumRow
                }

                ZStack {
                    Color.black.ignoresSafeArea()

                    if viewModel.library.photos.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("加载中…")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(viewModel.library.photos) { photo in
                                    PhotoThumbnailCell(
                                        photo: photo,
                                        library: viewModel.library,
                                        isSelected: selectedIds.contains(photo.id)
                                    ) {
                                        toggleSelection(photo.id)
                                    }
                                }
                            }
                            .padding(4)
                        }
                    }
                }
            }
            // 重开网格时把上次选过的勾回来
            .onAppear {
                if !preselected {
                    selectedIds = viewModel.lastSelectedIds
                    preselected = true
                }
                if albumIdSets.isEmpty {
                    fillAlbumIdSets()
                }
            }
            .navigationTitle("选择照片 (\(selectedIds.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isAllSelected ? "取消全选" : "全选") {
                        if isAllSelected {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(viewModel.library.photos.map { $0.id })
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("播放") {
                        if !selectedIds.isEmpty {
                            // 在目录里的直接用；不在目录里的
                            // （比如来源模式没把它列进去、或去重代表没进目录）
                            // 按 asset id 重建，保证勾选的全都能播
                            let inCatalog = viewModel.library.photos.filter {
                                selectedIds.contains($0.id)
                            }
                            var selected = inCatalog
                            let catalogIDs = Set(inCatalog.map { $0.id })
                            let missing = selectedIds.filter {
                                !catalogIDs.contains($0)
                            }
                            if !missing.isEmpty {
                                let result = PHAsset.fetchAssets(
                                    withLocalIdentifiers: Array(missing),
                                    options: nil)
                                result.enumerateObjects { asset, _, _ in
                                    guard asset.mediaType == .image else { return }
                                    selected.append(SlidePhoto(
                                        id: asset.localIdentifier,
                                        source: .asset(asset)))
                                }
                            }
                            viewModel.loadSelected(selected)
                        }
                        isPresented = false
                    }
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
    }

    // MARK: - 相册级勾选

    private var albumRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.library.albums) { album in
                    albumChip(album)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color.black)
    }

    private func albumChip(_ album: SlideAlbum) -> some View {
        let ids = albumIdSets[album.id] ?? []
        let allOn = !ids.isEmpty && selectedIds.isSuperset(of: ids)
        let someOn = !ids.isEmpty && ids.contains(where: selectedIds.contains)

        return Button(action: {
            if allOn {
                selectedIds.subtract(ids)          // 整册取消
            } else {
                selectedIds.formUnion(ids)         // 整册勾上
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: allOn ? "checkmark.square.fill"
                                        : someOn ? "square.fill"
                                        : "square")
                    .font(.system(size: 13))
                    .foregroundColor(allOn ? .green : .white.opacity(0.7))
                Text(album.isShared ? album.name + "（共享）" : album.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(allOn ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    /// 把每个相册的照片 id 集合算好。只在打开网格时算一次，
    /// 点 chip 时直接查表，不重复 fetch。
    ///
    /// 关键一步：被目录去重掉的照片（albumIds 里有、library.photos
    /// 里没有）要通过 library.aliasToRep 归一到留下的代表 id，
    /// 否则勾选了这个相册、它那份又正好是被去重掉的副本，
    /// 播放列表里就找不到那张照片了（按 id 过滤时落空）。
    private func fillAlbumIdSets() {
        var out: [String: Set<String>] = [:]
        for album in viewModel.library.albums {
            var ids = Set<String>()
            PHAsset.fetchAssets(in: album.collection, options: nil)
                .enumerateObjects { asset, _, _ in
                    guard asset.mediaType == .image else { return }
                    let assetID = asset.localIdentifier
                    ids.insert(viewModel.library.aliasToRep[assetID] ?? assetID)
                }
            out[album.id] = ids
        }
        albumIdSets = out
    }

    private var isAllSelected: Bool {
        !viewModel.library.photos.isEmpty
            && selectedIds.count == viewModel.library.photos.count
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }
}

// MARK: - 单个缩略图格子
//
// 独立成 View 是为了让选中状态变化时只重绘受影响的那一格，
// 而不是整个网格（5000 张照片时差异巨大）。

struct PhotoThumbnailCell: View {
    let photo: SlidePhoto
    let library: PhotoLibraryManager
    let isSelected: Bool
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.white.opacity(0.3))
                    )
            }

            if isSelected {
                Rectangle()
                    .fill(Color.blue.opacity(0.25))
                Rectangle()
                    .stroke(Color.blue, lineWidth: 3)
                Circle()
                    .fill(Color.blue)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "checkmark")
                            .foregroundColor(.white)
                            .font(.system(size: 12, weight: .bold))
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onAppear(perform: loadThumbnail)
    }

    private func loadThumbnail() {
        // 命中缓存就直接用，不重复请求
        if let cached = ThumbnailCache.shared.image(for: photo.id) {
            image = cached
            return
        }

        library.loadThumbnail(
            for: photo,
            size: CGSize(width: 240, height: 240)
        ) { img in
            guard let img = img else { return }
            ThumbnailCache.shared.store(img, for: photo.id)
            image = img
        }
    }
}

// MARK: - Preview

struct PhotoGridView_Previews: PreviewProvider {
    static var previews: some View {
        PhotoGridView(
            isPresented: .constant(true),
            viewModel: SlideShowViewModel()
        )
    }
}

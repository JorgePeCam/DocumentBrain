import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var searchText = ""
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var folderToRename: Folder?
    @State private var renameFolderName = ""
    @State private var documentToMove: String?
    @State private var showMoveSheet = false

    private var lang: AppLanguage { AppLanguage.current }

    private let columns = [
        GridItem(.flexible(), spacing: AppStyle.cardSpacing),
        GridItem(.flexible(), spacing: AppStyle.cardSpacing)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if !searchText.isEmpty {
                    contentSearchResultsList
                } else if viewModel.documents.isEmpty && viewModel.folders.isEmpty && !viewModel.isInFolder {
                    emptyState
                } else {
                    contentGrid
                }
            }
            .navigationTitle(viewModel.currentFolderName)
            .navigationBarTitleDisplayMode(viewModel.isInFolder ? .inline : .large)
            .searchable(text: $searchText, prompt: lang.librarySearch)
            .onChange(of: searchText) { _, newValue in
                viewModel.searchContent(query: newValue)
            }
            .toolbar {
                if viewModel.isInFolder {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            viewModel.navigateBack()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(lang.libraryBack)
                            }
                            .foregroundStyle(Color.appAccent)
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 4) {
                            filterMenu
                            sortMenu
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            viewModel.showImporter = true
                        } label: {
                            Label(lang.libraryFromFiles, systemImage: "doc.badge.plus")
                        }

                        Button {
                            viewModel.showCamera = true
                        } label: {
                            Label(lang.libraryTakePhoto, systemImage: "camera")
                        }

                        Divider()

                        Button {
                            showNewFolderAlert = true
                        } label: {
                            Label(lang.libraryNewFolder, systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.appAccent)
                    }
                    .accessibilityLabel(lang.libraryNewFolder)
                }
            }
            .fileImporter(
                isPresented: $viewModel.showImporter,
                allowedContentTypes: viewModel.allowedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                viewModel.handleFileImport(result: result)
            }
            .sheet(isPresented: $viewModel.showCamera) {
                ImagePicker(sourceType: .camera) { image in
                    viewModel.handleCameraCapture(image: image)
                }
            }
            .sheet(isPresented: $showMoveSheet) {
                moveToFolderSheet
            }
            .task {
                await viewModel.loadDocuments()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sharedInboxDidImportDocuments)) { _ in
                Task {
                    await viewModel.loadDocuments()
                }
            }
            .alert(lang.libraryNewFolder, isPresented: $showNewFolderAlert) {
                TextField(lang.libraryFolderNameField, text: $newFolderName)
                Button(lang.libraryCreate) {
                    viewModel.createFolder(name: newFolderName)
                    newFolderName = ""
                }
                Button(lang.cancelButton, role: .cancel) { newFolderName = "" }
            }
            .alert(lang.libraryRenameFolderTitle, isPresented: .isPresent($folderToRename)) {
                TextField(lang.libraryFolderNameField, text: $renameFolderName)
                Button(lang.libraryRename) {
                    if let folder = folderToRename {
                        viewModel.renameFolder(folder, newName: renameFolderName)
                    }
                    folderToRename = nil
                    renameFolderName = ""
                }
                Button(lang.cancelButton, role: .cancel) {
                    folderToRename = nil
                    renameFolderName = ""
                }
            }
            .alert("Error", isPresented: .isPresent($viewModel.userErrorMessage)) {
                Button(lang.okButton, role: .cancel) { viewModel.userErrorMessage = nil }
            } message: {
                Text(viewModel.userErrorMessage ?? lang.errorGeneric)
            }
        }
    }

    // MARK: - Filter Menu

    private var filterMenu: some View {
        Menu {
            Button {
                viewModel.filterType = nil
            } label: {
                Label(lang.libraryAll, systemImage: viewModel.filterType == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(FileType.allCases, id: \.self) { type in
                Button {
                    viewModel.filterType = type
                } label: {
                    Label(type.displayName, systemImage: type.systemImage)
                }
            }
        } label: {
            Image(systemName: viewModel.filterType != nil
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.appAccent)
        }
        .accessibilityLabel(lang.libraryAll)
    }

    // MARK: - Sort Menu

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySortOption.allCases, id: \.self) { option in
                Button {
                    viewModel.sortOption = option
                } label: {
                    HStack {
                        Label(option.label, systemImage: option.icon)
                        if viewModel.sortOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.appAccent)
        }
        .accessibilityLabel(lang.librarySortTitle)
    }

    // MARK: - Processing Banner

    private var processingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(Color.appAccent)

            Text(lang.processingDocuments)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(viewModel.processingCount)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.appAccentLight)
                .clipShape(Capsule())
        }
        .padding(.horizontal, AppStyle.padding)
        .padding(.vertical, 8)
        .background(Color.appAccentSoft)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(LinearGradient.accentSoftGradient)
                    .frame(width: 120, height: 120)

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.appAccent)
            }

            VStack(spacing: 8) {
                Text(lang.libraryEmptyTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(lang.libraryEmptySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button {
                    viewModel.showImporter = true
                } label: {
                    Label(lang.libraryImportFiles, systemImage: "folder.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .controlSize(.large)

                Button {
                    viewModel.showCamera = true
                } label: {
                    Label(lang.libraryScanDocument, systemImage: "camera.fill")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.bordered)
                .tint(Color.appAccent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(AppStyle.paddingLarge)
    }

    // MARK: - Content Grid

    private var contentGrid: some View {
        ScrollView {
            // Processing banner
            if viewModel.hasProcessingDocuments {
                processingBanner
            }

            // Breadcrumb (only when navigated into a folder)
            if viewModel.isInFolder {
                breadcrumb
            }

            // Empty folder state
            let totalItems = viewModel.folders.count + filteredDocuments.count
            if totalItems == 0 && viewModel.isInFolder {
                emptyFolderState
            }

            // Item count header
            if totalItems > 0 {
                HStack {
                    Text(lang.libraryItemCount(totalItems))
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, AppStyle.padding)
                .padding(.top, 4)
            }

            LazyVGrid(columns: columns, spacing: AppStyle.cardSpacing) {
                // Folders first
                ForEach(viewModel.folders) { folder in
                    Button {
                        viewModel.navigateToFolder(folder)
                    } label: {
                        FolderCard(
                            folder: folder,
                            documentCount: viewModel.documentCounts[folder.id] ?? 0
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameFolderName = folder.name
                            folderToRename = folder
                        } label: {
                            Label(lang.libraryRename, systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            viewModel.deleteFolder(id: folder.id)
                        } label: {
                            Label(lang.libraryDeleteFolder, systemImage: "trash")
                        }
                    }
                }

                // Then documents
                ForEach(filteredDocuments) { document in
                    NavigationLink(value: document.id) {
                        DocumentCard(document: document)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if document.processingStatusEnum == .error {
                            Button {
                                viewModel.retryDocument(id: document.id)
                            } label: {
                                Label(lang.libraryRetry, systemImage: "arrow.clockwise")
                            }
                            Divider()
                        }

                        Button {
                            documentToMove = document.id
                            showMoveSheet = true
                        } label: {
                            Label(lang.libraryMoveToFolder, systemImage: "folder")
                        }

                        if viewModel.isInFolder {
                            Button {
                                viewModel.moveDocument(document.id, toFolder: nil)
                            } label: {
                                Label(lang.libraryRemoveFromFolder, systemImage: "arrow.up.doc")
                            }
                        }

                        Button(role: .destructive) {
                            viewModel.deleteDocument(id: document.id)
                        } label: {
                            Label(lang.libraryDeleteDoc, systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, AppStyle.padding)
            .padding(.bottom, AppStyle.padding)
        }
        .navigationDestination(for: String.self) { documentId in
            DocumentDetailView(documentId: documentId)
        }
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    viewModel.navigateToRoot()
                } label: {
                    Text(lang.libraryTitle)
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                }

                ForEach(Array(viewModel.folderPath.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if index == viewModel.folderPath.count - 1 {
                        Text(folder.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                    } else {
                        Button {
                            // Navigate to this level
                            let newPath = Array(viewModel.folderPath.prefix(index + 1))
                            viewModel.navigateToPath(newPath)
                        } label: {
                            Text(folder.name)
                                .font(.caption)
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                }
            }
            .padding(.horizontal, AppStyle.padding)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Empty Folder State

    private var emptyFolderState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 40)

            VStack(spacing: 6) {
                Text(lang.libraryFolderEmpty)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(lang.libraryFolderEmptySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    // MARK: - Move Sheet

    private var moveToFolderSheet: some View {
        NavigationStack {
            List {
                // Always show root as option
                Button {
                    if let docId = documentToMove {
                        viewModel.moveDocument(docId, toFolder: nil)
                    }
                    showMoveSheet = false
                    documentToMove = nil
                } label: {
                    Label(lang.libraryRootFolder, systemImage: "house")
                }

                // All folders hierarchically
                ForEach(hierarchicalFolders, id: \.folder.id) { item in
                    Button {
                        if let docId = documentToMove {
                            viewModel.moveDocument(docId, toFolder: item.folder.id)
                        }
                        showMoveSheet = false
                        documentToMove = nil
                    } label: {
                        HStack(spacing: 4) {
                            // Indentation for depth
                            if item.depth > 0 {
                                Color.clear.frame(width: CGFloat(item.depth) * 16)
                            }
                            Label(item.folder.name, systemImage: "folder.fill")
                        }
                    }
                }

                if viewModel.allFolders.isEmpty {
                    Text(lang.libraryNoFolders)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(lang.libraryMoveToTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang.cancelButton) {
                        showMoveSheet = false
                        documentToMove = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Content Search Results

    private var contentSearchResultsList: some View {
        Group {
            if viewModel.isSearchingContent {
                VStack {
                    Spacer()
                    ProgressView()
                        .tint(Color.appAccent)
                    Spacer()
                }
            } else if viewModel.contentSearchResults.isEmpty && searchText.count >= 2 {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Sin resultados para «\(searchText)»")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Prueba con otras palabras")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                List(viewModel.contentSearchResults) { result in
                    NavigationLink(value: result.documentId) {
                        contentSearchRow(result)
                    }
                    .listRowBackground(Color.appCard)
                }
                .listStyle(.plain)
            }
        }
    }

    private func contentSearchRow(_ result: ContentSearchResult) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient.accentSoftGradient)
                    .frame(width: 40, height: 40)
                Image(systemName: result.fileTypeEnum.systemImage)
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Color.appAccent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(result.documentTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(result.highlightedSnippet(for: searchText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private var filteredDocuments: [Document] {
        let docs = viewModel.filteredDocuments
        if searchText.isEmpty { return docs }
        return docs.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private struct HierarchicalFolder {
        let folder: Folder
        let depth: Int
    }

    private var hierarchicalFolders: [HierarchicalFolder] {
        func children(of parentId: String?, depth: Int) -> [HierarchicalFolder] {
            viewModel.allFolders
                .filter { $0.parentFolderId == parentId }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .flatMap { folder in
                    [HierarchicalFolder(folder: folder, depth: depth)] +
                    children(of: folder.id, depth: depth + 1)
                }
        }
        return children(of: nil, depth: 0)
    }
}

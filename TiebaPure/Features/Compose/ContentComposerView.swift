import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentComposerView: View {
    let target: ContentSubmissionTarget

    private let onCancel: () -> Void
    private let onSaveDraft: (ContentSubmissionRequest) async throws -> Void
    private let onSend: (ContentSubmissionRequest) async throws -> ContentSubmissionReceipt
    private let onSent: (ContentSubmissionReceipt) -> Void

    @State private var title: String
    @State private var bodyText: String
    @State private var attachments: [ContentSubmissionImage]
    @State private var savedSnapshot: ContentComposerSnapshot
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var photoLoadingTask: Task<Void, Never>?
    @State private var photoLoadProgress: (completed: Int, total: Int)?
    @State private var attachmentErrorMessage: String?
    @State private var submissionState: ContentComposerSubmissionState = .idle
    @State private var isSavingDraft = false
    @State private var draftStatusMessage: String?
    @State private var showsEmoticons = false
    @State private var showsUnsavedChangesConfirmation = false
    @State private var activeChallenge: ContentSubmissionChallenge?
    @State private var showsVerificationSheet = false
    @State private var showsFailureAlert = false
    @State private var submissionFailureMessage = ""
    @StateObject private var dismissalGate = ContentComposerDismissalGate()
    @StateObject private var editorController = EmoticonTextEditorController()

    @FocusState private var focusedField: ContentComposerField?
    @ScaledMetric(relativeTo: .body) private var editorMinimumHeight = 180

    init(
        target: ContentSubmissionTarget,
        initialTitle: String = "",
        initialBody: String = "",
        initialImages: [ContentSubmissionImage] = [],
        onCancel: @escaping () -> Void,
        onSaveDraft: @escaping (ContentSubmissionRequest) async throws -> Void,
        onSend: @escaping (ContentSubmissionRequest) async throws -> ContentSubmissionReceipt,
        onSent: @escaping (ContentSubmissionReceipt) -> Void = { _ in }
    ) {
        self.target = target
        self.onCancel = onCancel
        self.onSaveDraft = onSaveDraft
        self.onSend = onSend
        self.onSent = onSent
        let initialAttachments = Array(initialImages.prefix(
            ContentComposerPolicy.maximumImages(for: target.kind)
        ))
        _title = State(initialValue: initialTitle)
        _bodyText = State(initialValue: initialBody)
        _attachments = State(initialValue: initialAttachments)
        _savedSnapshot = State(initialValue: ContentComposerSnapshot(
            title: initialTitle,
            body: initialBody,
            images: initialAttachments
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(target.prompt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if target.kind == .newThread {
                        titleSection
                    }

                    bodySection

                    if attachments.isEmpty == false || photoLoadProgress != nil {
                        attachmentSection
                    }

                    statusSection
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("content-composer-scroll-view")
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(target.kind.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { navigationToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if showsEmoticons {
                        Divider()
                        emoticonSection
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    actionBar
                }
                .background(.bar)
            }
            .compatibleOnChange(of: focusedField) { _, field in
                guard field != nil, showsEmoticons else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsEmoticons = false
                }
            }
        }
        .confirmationDialog(
            "保存未发送的更改？",
            isPresented: $showsUnsavedChangesConfirmation,
            titleVisibility: .visible
        ) {
            Button("保存草稿并关闭") {
                persistDraft(thenClose: true)
            }
            Button("放弃更改", role: .destructive) {
                closeProgrammatically()
            }
            Button("继续编辑") {}
        } message: {
            Text("保存后可在同一位置继续编辑；放弃后，本次未保存的更改无法恢复。")
        }
        .background {
            ContentComposerDismissObserver(
                gate: dismissalGate,
                canDismiss: allowsDismissal,
                onAttempt: requestClose,
                onDismissed: onCancel
            )
        }
        .compatibleOnChange(of: photoSelection) { _, newValue in
            preparePhotoSelection(newValue)
        }
        .alert(
            "发送失败",
            isPresented: $showsFailureAlert
        ) {
            Button("好", role: .cancel) {
                showsFailureAlert = false
            }
        } message: {
            Text(submissionFailureMessage)
        }
        .sheet(isPresented: $showsVerificationSheet) {
            if let challenge = activeChallenge {
                ContentComposerVerificationSheet(
                    challenge: challenge,
                    onSubmit: { code in
                        submitVerification(code: code)
                    },
                    onCancel: {
                        showsVerificationSheet = false
                    }
                )
            }
        }
        .onDisappear {
            photoLoadingTask?.cancel()
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("标题")
                    .font(.headline)
                Spacer(minLength: 12)
                characterCounter(
                    title.count,
                    limit: ContentSubmissionPolicy.maximumTitleCharacters
                )
            }

            TextField("请输入帖子标题", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...3)
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit { focusedField = .body }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                }
                .accessibilityLabel("帖子标题")
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("正文")
                    .font(.headline)
                Spacer(minLength: 12)
                characterCounter(
                    bodyText.count,
                    limit: ContentSubmissionPolicy.maximumBodyCharacters
                )
            }

            ZStack(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text(target.kind == .newThread ? "请输入帖子正文" : "请输入回复内容")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 17)
                        .allowsHitTesting(false)
                }

                EmoticonTextEditor(
                    text: $bodyText,
                    isFocused: Binding(
                        get: { focusedField == .body },
                        set: { if $0 { focusedField = .body } else if focusedField == .body { focusedField = nil } }
                    ),
                    controller: editorController
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: max(editorMinimumHeight, 132))
                .accessibilityLabel("正文内容")
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(uiColor: .separator), lineWidth: 0.5)
            }
        }
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("图片")
                    .font(.headline)
                Spacer(minLength: 12)
                Text("\(attachments.count)/\(ContentSubmissionPolicy.maximumImages)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(attachments) { attachment in
                        ContentComposerAttachmentView(attachment: attachment) {
                            removeAttachment(id: attachment.id)
                        }
                    }

                    if let progress = photoLoadProgress {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("\(progress.completed)/\(progress.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 88, height: 88)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("正在处理图片")
                        .accessibilityValue("已完成 \(progress.completed) 张，共 \(progress.total) 张")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emoticonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("表情")
                    .font(.headline)
                Spacer()
                Button {
                    showsEmoticons = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起表情")
            }

            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: [GridItem(.fixed(44), spacing: 8), GridItem(.fixed(44), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(ContentComposerEmoticonCatalog.entries) { entry in
                        ContentComposerEmoticonButton(entry: entry) {
                            if let handler = editorController.insertEmoticonHandler {
                                handler(entry.token, entry.imageName)
                            } else {
                                bodyText = ContentComposerPolicy.appendingEmoticon(
                                    entry.token,
                                    to: bodyText
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .frame(height: 98)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachmentErrorMessage {
                ContentComposerStatusView(
                    message: attachmentErrorMessage,
                    systemImage: "photo.badge.exclamationmark",
                    tint: .red
                )
            }

            if let draftStatusMessage {
                ContentComposerStatusView(
                    message: draftStatusMessage,
                    systemImage: "doc.badge.checkmark",
                    tint: .secondary
                )
            }

            switch submissionState {
            case .idle, .submitting:
                EmptyView()
            case .sent:
                ContentComposerStatusView(
                    message: "发送成功",
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            case let .failed(message):
                ContentComposerStatusView(
                    message: message,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                .accessibilityIdentifier("content-composer-submission-error")
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消", action: requestClose)
                .disabled(isBusy)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint(isBusy ? "发送或保存完成后可取消" : "关闭编辑器")
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(action: submit) {
                if submissionState == .submitting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("正在发送")
                } else {
                    Text("发送")
                        .fontWeight(.semibold)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .disabled(canSubmit == false)
            .accessibilityHint(canSubmit ? "发送当前内容" : sendDisabledReason)
        }
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                mediaButton
                emoticonButton
                Spacer(minLength: 8)
                draftButton
            }

            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    mediaButton
                    emoticonButton
                    Spacer(minLength: 8)
                }
                HStack {
                    Spacer(minLength: 0)
                    draftButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private var mediaButton: some View {
        let remaining = ContentComposerPolicy.remainingImageSlots(
            currentCount: attachments.count,
            kind: target.kind
        )
        if target.kind == .newThread {
            EmptyView()
        } else if remaining > 0 {
            PhotosPicker(
                selection: $photoSelection,
                maxSelectionCount: remaining,
                matching: .images,
                preferredItemEncoding: .current
            ) {
                Label("图片", systemImage: "photo.on.rectangle.angled")
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .disabled(isBusy || photoLoadProgress != nil)
            .accessibilityHint("还可添加 \(remaining) 张")
        } else {
            Label("图片", systemImage: "photo.on.rectangle.angled")
                .foregroundStyle(.tertiary)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
                .accessibilityLabel("图片数量已达上限")
        }
    }

    private var emoticonButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if showsEmoticons {
                    showsEmoticons = false
                } else {
                    focusedField = nil
                    showsEmoticons = true
                }
            }
        } label: {
            Label("表情", systemImage: "face.smiling")
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || photoLoadProgress != nil)
        .accessibilityValue(showsEmoticons ? "已展开" : "已收起")
    }

    private var draftButton: some View {
        Button(action: saveDraft) {
            if isSavingDraft {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 88, minHeight: 44)
                    .accessibilityLabel("正在保存草稿")
            } else {
                Label("保存草稿", systemImage: "doc.badge.plus")
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy || photoLoadProgress != nil)
    }

    private var currentRequest: ContentSubmissionRequest {
        ContentSubmissionRequest(
            target: target,
            title: title,
            body: bodyText,
            images: attachments
        )
    }

    private var currentSnapshot: ContentComposerSnapshot {
        ContentComposerSnapshot(title: title, body: bodyText, images: attachments)
    }

    private var hasUnsavedChanges: Bool {
        currentSnapshot != savedSnapshot
    }

    private var isBusy: Bool {
        submissionState == .submitting || isSavingDraft
    }

    private var allowsDismissal: Bool {
        isBusy == false && (hasUnsavedChanges == false || submissionState.didSucceed)
    }

    private var canSubmit: Bool {
        guard isBusy == false,
              photoLoadProgress == nil,
              submissionState.didSucceed == false else {
            return false
        }
        return ContentComposerPolicy.validationMessage(for: currentRequest) == nil
    }

    private var sendDisabledReason: String {
        if submissionState.didSucceed {
            return "内容已发送"
        }
        if photoLoadProgress != nil {
            return "图片仍在处理中"
        }
        return ContentComposerPolicy.validationMessage(for: currentRequest) ?? "暂时无法发送"
    }

    private func characterCounter(_ count: Int, limit: Int) -> some View {
        Text("\(count)/\(limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(count > limit ? Color.red : Color.secondary)
            .accessibilityLabel("已输入 \(count) 个字符，上限 \(limit) 个字符")
    }

    private func submit() {
        guard isBusy == false, submissionState.didSucceed == false else { return }
        let request = currentRequest
        if let message = ContentComposerPolicy.validationMessage(for: request) {
            submissionState = .failed(message)
            submissionFailureMessage = message
            showsFailureAlert = true
            return
        }
        performSubmit(request: request)
    }

    private func performSubmit(request: ContentSubmissionRequest) {
        focusedField = nil
        draftStatusMessage = nil
        submissionState = .submitting
        Task {
            do {
                let receipt = try await onSend(request)
                // A successful write is irreversible. Consume its receipt even
                // if SwiftUI cancelled the view-owned caller while it awaited.
                submissionState = .sent(receipt)
                dismissalGate.allowProgrammaticDismissal()
                onSent(receipt)
            } catch is CancellationError {
                submissionState = .idle
            } catch let ContentSubmissionError.verificationRequired(challenge) {
                activeChallenge = challenge
                showsVerificationSheet = true
                submissionState = .idle
            } catch {
                submissionState = .failed(error.localizedDescription)
                submissionFailureMessage = error.localizedDescription
                showsFailureAlert = true
            }
        }
    }

    private func submitVerification(code: String) {
        guard let challenge = activeChallenge else { return }
        showsVerificationSheet = false
        var request = currentRequest
        request.verificationCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        request.verificationMD5 = challenge.verificationMD5
        request.verificationType = challenge.verificationType
        performSubmit(request: request)
    }

    private func saveDraft() {
        persistDraft(thenClose: false)
    }

    private func requestClose() {
        guard isBusy == false else { return }
        guard hasUnsavedChanges else {
            closeProgrammatically()
            return
        }
        focusedField = nil
        showsUnsavedChangesConfirmation = true
    }

    private func persistDraft(thenClose: Bool) {
        guard isBusy == false, photoLoadProgress == nil else { return }
        let request = currentRequest
        isSavingDraft = true
        draftStatusMessage = nil
        Task {
            var didSave = false
            do {
                try await onSaveDraft(request)
                // Once persistence reports success, consume it even if the
                // view-owned task was cancelled during the final disk write.
                savedSnapshot = ContentComposerSnapshot(
                    title: request.title,
                    body: request.body,
                    images: request.images
                )
                draftStatusMessage = "草稿已保存"
                didSave = true
            } catch is CancellationError {
                // The caller owns cancellation; do not turn it into an error banner.
            } catch {
                draftStatusMessage = "草稿保存失败：\(error.localizedDescription)"
            }
            isSavingDraft = false
            if thenClose, didSave {
                DispatchQueue.main.async {
                    closeProgrammatically()
                }
            }
        }
    }

    private func closeProgrammatically() {
        dismissalGate.allowProgrammaticDismissal()
        onCancel()
    }

    private func preparePhotoSelection(_ selection: [PhotosPickerItem]) {
        guard selection.isEmpty == false else { return }
        photoLoadingTask?.cancel()

        let remaining = ContentComposerPolicy.remainingImageSlots(
            currentCount: attachments.count,
            kind: target.kind
        )
        let items = Array(selection.prefix(remaining))
        photoSelection = []
        guard items.isEmpty == false else { return }

        attachmentErrorMessage = nil
        photoLoadProgress = (0, items.count)
        photoLoadingTask = Task {
            var prepared: [ContentSubmissionImage] = []
            var firstErrorMessage: String?

            for (index, item) in items.enumerated() {
                guard Task.isCancelled == false else { return }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ContentSubmissionValidationError.invalidImage
                    }
                    let image = try await Task.detached(priority: .userInitiated) {
                        try ContentComposerImageDecoder.decode(data)
                    }.value
                    prepared.append(image)
                } catch is CancellationError {
                    return
                } catch {
                    firstErrorMessage = firstErrorMessage ?? error.localizedDescription
                }
                photoLoadProgress = (index + 1, items.count)
            }

            guard Task.isCancelled == false else { return }
            let available = ContentComposerPolicy.remainingImageSlots(
                currentCount: attachments.count,
                kind: target.kind
            )
            attachments.append(contentsOf: prepared.prefix(available))
            attachmentErrorMessage = firstErrorMessage
            photoLoadProgress = nil
            photoLoadingTask = nil
            if submissionState.didSucceed == false {
                submissionState = .idle
            }
        }
    }

    private func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        attachmentErrorMessage = nil
        if submissionState.didSucceed == false {
            submissionState = .idle
        }
    }
}

private struct ContentComposerSnapshot: Equatable {
    var title: String
    var body: String
    var images: [ContentSubmissionImage]
}

private struct ContentComposerDismissObserver: UIViewControllerRepresentable {
    let gate: ContentComposerDismissalGate
    let canDismiss: Bool
    let onAttempt: () -> Void
    let onDismissed: () -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        let controller = ObserverViewController()
        controller.update(
            gate: gate,
            canDismiss: canDismiss,
            onAttempt: onAttempt,
            onDismissed: onDismissed
        )
        return controller
    }

    func updateUIViewController(_ controller: ObserverViewController, context: Context) {
        controller.update(
            gate: gate,
            canDismiss: canDismiss,
            onAttempt: onAttempt,
            onDismissed: onDismissed
        )
    }

    static func dismantleUIViewController(
        _ controller: ObserverViewController,
        coordinator: ()
    ) {
        controller.detach()
    }

    @MainActor
    final class ObserverViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
        private weak var gate: ContentComposerDismissalGate?
        private var canDismiss = true
        private var onAttempt: () -> Void = {}
        private var onDismissed: () -> Void = {}
        private weak var observedPresentationController: UIPresentationController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachToPresentationController()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in
                self?.attachToPresentationController()
            }
        }

        func update(
            gate: ContentComposerDismissalGate,
            canDismiss: Bool,
            onAttempt: @escaping () -> Void,
            onDismissed: @escaping () -> Void
        ) {
            self.gate = gate
            self.canDismiss = canDismiss
            gate.updateInteractiveDismissal(canDismiss)
            self.onAttempt = onAttempt
            self.onDismissed = onDismissed
            DispatchQueue.main.async { [weak self] in
                self?.attachToPresentationController()
            }
        }

        func detach() {
            if observedPresentationController?.delegate === self {
                observedPresentationController?.delegate = nil
            }
            observedPresentationController = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            gate?.allowsDismissal ?? canDismiss
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismissed()
        }

        private func attachToPresentationController() {
            var candidate: UIViewController? = self
            var enclosingPresentationController: UIPresentationController?
            while let controller = candidate {
                if let presentationController = controller.presentationController {
                    enclosingPresentationController = presentationController
                }
                candidate = controller.parent
            }
            guard let enclosingPresentationController else { return }
            if observedPresentationController !== enclosingPresentationController {
                detach()
                observedPresentationController = enclosingPresentationController
            }
            enclosingPresentationController.delegate = self
        }
    }
}

@MainActor
private final class ContentComposerDismissalGate: ObservableObject {
    private var allowsInteractiveDismissal = true
    private var allowsProgrammaticDismissal = false

    var allowsDismissal: Bool {
        allowsProgrammaticDismissal || allowsInteractiveDismissal
    }

    func updateInteractiveDismissal(_ isAllowed: Bool) {
        allowsInteractiveDismissal = isAllowed
    }

    func allowProgrammaticDismissal() {
        allowsProgrammaticDismissal = true
    }
}

enum ContentComposerPolicy {
    static func showsTitle(for kind: ContentSubmissionKind) -> Bool {
        kind == .newThread
    }

    static func maximumImages(for kind: ContentSubmissionKind) -> Int {
        kind == .newThread ? 0 : ContentSubmissionPolicy.maximumImages
    }

    static func remainingImageSlots(currentCount: Int, kind: ContentSubmissionKind) -> Int {
        max(0, maximumImages(for: kind) - max(0, currentCount))
    }

    static func validationMessage(for request: ContentSubmissionRequest) -> String? {
        do {
            try ContentSubmissionPolicy.validate(request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func appendingEmoticon(_ token: String, to text: String) -> String {
        guard text.isEmpty == false else { return token }
        guard let last = text.last, last.isWhitespace == false else { return text + token }
        if last == ")" {
            return text + token
        }
        return text + " " + token
    }
}

enum ContentComposerImageDecoder {
    static func decode(_ data: Data) throws -> ContentSubmissionImage {
        let sanitizedData = try ContentSubmissionImageSanitizer.sanitize(data)
        let metadata = try ContentSubmissionImageInspector.inspect(sanitizedData)

        return ContentSubmissionImage(
            data: sanitizedData,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            mimeType: metadata.mimeType
        )
    }

    static func thumbnailData(from data: Data, maximumPixelSize: Int = 240) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.82)
    }
}

enum ContentSubmissionImageSanitizer {
    private static let destinationTypeIdentifiers = Set(
        CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    )

    static func sanitize(_ data: Data) throws -> Data {
        _ = try ContentSubmissionImageInspector.inspect(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceTypeIdentifier = CGImageSourceGetType(source) as String? else {
            throw ContentSubmissionValidationError.invalidImage
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0,
              let firstFrame = normalizedFrame(from: source, at: 0) else {
            throw ContentSubmissionValidationError.invalidImage
        }
        let destinationTypeIdentifier = destinationTypeIdentifier(
            sourceTypeIdentifier: sourceTypeIdentifier,
            frameCount: frameCount,
            firstFrame: firstFrame
        )
        let sanitizedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            sanitizedData,
            destinationTypeIdentifier as CFString,
            frameCount,
            nil
        ) else {
            throw ContentSubmissionValidationError.invalidImage
        }

        if let properties = containerProperties(
            from: source,
            destinationTypeIdentifier: destinationTypeIdentifier
        ) {
            CGImageDestinationSetProperties(destination, properties as CFDictionary)
        }

        for index in 0..<frameCount {
            guard let frame = index == 0 ? firstFrame : normalizedFrame(from: source, at: index) else {
                throw ContentSubmissionValidationError.invalidImage
            }
            let properties = frameProperties(
                from: source,
                at: index,
                destinationTypeIdentifier: destinationTypeIdentifier
            )
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ContentSubmissionValidationError.invalidImage
        }
        let result = sanitizedData as Data
        _ = try ContentSubmissionImageInspector.inspect(result)
        return result
    }

    private static func destinationTypeIdentifier(
        sourceTypeIdentifier: String,
        frameCount: Int,
        firstFrame: CGImage
    ) -> String {
        if destinationTypeIdentifiers.contains(sourceTypeIdentifier) {
            return sourceTypeIdentifier
        }
        if frameCount > 1, destinationTypeIdentifiers.contains(UTType.gif.identifier) {
            return UTType.gif.identifier
        }
        if hasAlpha(firstFrame) {
            return UTType.png.identifier
        }
        return UTType.jpeg.identifier
    }

    private static func normalizedFrame(from source: CGImageSource, at index: Int) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= ContentSubmissionPolicy.maximumPixelDimension,
              height <= ContentSubmissionPolicy.maximumPixelDimension,
              Int64(width) * Int64(height) <= Int64(ContentSubmissionPolicy.maximumPixelCount) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return true
        }
    }

    private static func containerProperties(
        from source: CGImageSource,
        destinationTypeIdentifier: String
    ) -> [CFString: Any]? {
        guard let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else {
            return nil
        }
        if destinationTypeIdentifier == UTType.gif.identifier,
           let sourceGIF = sourceProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loopCount = sourceGIF[kCGImagePropertyGIFLoopCount] as? NSNumber {
            return [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: loopCount
                ]
            ]
        }
        if destinationTypeIdentifier == UTType.png.identifier,
           let sourcePNG = sourceProperties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let loopCount = sourcePNG[kCGImagePropertyAPNGLoopCount] as? NSNumber {
            return [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGLoopCount: loopCount
                ]
            ]
        }
        return nil
    }

    private static func frameProperties(
        from source: CGImageSource,
        at index: Int,
        destinationTypeIdentifier: String
    ) -> [CFString: Any] {
        var result: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        guard let sourceProperties = CGImageSourceCopyPropertiesAtIndex(
            source,
            index,
            nil
        ) as? [CFString: Any] else {
            return result
        }

        if destinationTypeIdentifier == UTType.gif.identifier,
           let sourceGIF = sourceProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            var gif: [CFString: Any] = [:]
            copyNumber(kCGImagePropertyGIFDelayTime, from: sourceGIF, to: &gif)
            copyNumber(kCGImagePropertyGIFUnclampedDelayTime, from: sourceGIF, to: &gif)
            if gif.isEmpty == false {
                result[kCGImagePropertyGIFDictionary] = gif
            }
        } else if destinationTypeIdentifier == UTType.png.identifier,
                  let sourcePNG = sourceProperties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            var png: [CFString: Any] = [:]
            copyNumber(kCGImagePropertyAPNGDelayTime, from: sourcePNG, to: &png)
            copyNumber(kCGImagePropertyAPNGUnclampedDelayTime, from: sourcePNG, to: &png)
            if png.isEmpty == false {
                result[kCGImagePropertyPNGDictionary] = png
            }
        }
        return result
    }

    private static func copyNumber(
        _ key: CFString,
        from source: [CFString: Any],
        to destination: inout [CFString: Any]
    ) {
        if let value = source[key] as? NSNumber {
            destination[key] = value
        }
    }
}

private enum ContentComposerField: Hashable {
    case title
    case body
}

private enum ContentComposerSubmissionState: Equatable {
    case idle
    case submitting
    case sent(ContentSubmissionReceipt)
    case failed(String)

    var didSucceed: Bool {
        if case .sent = self { return true }
        return false
    }
}

struct ContentComposerEmoticon: Identifiable, Equatable, Sendable {
    let imageName: String
    let label: String
    let token: String

    var id: String { imageName }
}

enum ContentComposerEmoticonCatalog {
    private static let imageNumbers = Array(1...50) + Array(77...84) + [89]

    static let entries: [ContentComposerEmoticon] = imageNumbers.compactMap { number in
        let imageName = "image_emoticon\(number)"
        guard TiebaEmoticon.imageName(for: imageName) != nil else { return nil }
        let displayText = TiebaEmoticon.displayText(for: imageName)
        let label = String(displayText.dropFirst().dropLast())
        return ContentComposerEmoticon(
            imageName: imageName,
            label: label,
            token: "#(\(label))"
        )
    }
}

private struct ContentComposerEmoticonButton: View {
    let entry: ContentComposerEmoticon
    let action: () -> Void

    @StateObject private var artwork: TiebaEmoticonArtworkObserver

    init(entry: ContentComposerEmoticon, action: @escaping () -> Void) {
        self.entry = entry
        self.action = action
        _artwork = StateObject(wrappedValue: TiebaEmoticonArtworkObserver(
            imageNames: [entry.imageName]
        ))
    }

    var body: some View {
        let _ = artwork.revision
        Button(action: action) {
            Group {
                if let image = TiebaEmoticon.cachedImage(for: entry.imageName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Text(entry.label)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(4)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("插入\(entry.label)表情")
        .accessibilityIdentifier("content-composer-emoticon-\(entry.imageName)")
    }
}

private struct ContentComposerAttachmentView: View {
    let attachment: ContentSubmissionImage
    let onRemove: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(uiColor: .tertiarySystemFill)
                        .overlay { ProgressView() }
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除图片")
        }
        .frame(width: 88, height: 88)
        .accessibilityElement(children: .contain)
        .task(id: attachment.id) {
            let data = attachment.data
            let thumbnailData = await Task.detached(priority: .utility) {
                ContentComposerImageDecoder.thumbnailData(from: data)
            }.value
            guard Task.isCancelled == false, let thumbnailData else { return }
            thumbnail = UIImage(data: thumbnailData)
        }
    }
}

private struct ContentComposerStatusView: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

private struct ContentComposerVerificationSheet: View {
    let challenge: ContentSubmissionChallenge
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var code: String = ""
    @State private var refreshID = UUID()
    @FocusState private var isFocused: Bool

    private var imageURL: URL? {
        guard let baseURL = challenge.pictureURL else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll(where: { $0.name == "_r" })
        queryItems.append(URLQueryItem(name: "_r", value: refreshID.uuidString))
        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(challenge.message.isEmpty ? "贴吧要求安全验证，请输入图片中的字符。" : challenge.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    if let imageURL {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 140, height: 50)
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 140, height: 50)
                            case .failure:
                                VStack(spacing: 2) {
                                    Image(systemName: "exclamationmark.triangle")
                                    Text("加载失败")
                                        .font(.caption2)
                                }
                                .frame(width: 140, height: 50)
                                .foregroundStyle(.secondary)
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                        )
                    }

                    Button {
                        refreshID = UUID()
                    } label: {
                        Label("换一张", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }

                TextField("请输入验证码", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit {
                        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty == false {
                            onSubmit(trimmed)
                        }
                    }

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("安全验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSubmit(trimmed)
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Rich Emoticon Text Editor

/// An attachment that renders a Tieba emoticon inline while preserving its textual token (e.g. `#(滑稽)`).
final class EmoticonTextAttachment: NSTextAttachment {
    let token: String
    let imageName: String

    init(token: String, imageName: String, image: UIImage?, font: UIFont) {
        self.token = token
        self.imageName = imageName
        super.init(data: nil, ofType: nil)
        self.image = image
        updateBounds(for: font)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateBounds(for font: UIFont) {
        let size = ceil(font.lineHeight)
        // Center the emoticon vertically against the font's cap-height.
        let yOffset = floor((font.capHeight - size) / 2.0)
        self.bounds = CGRect(x: 0, y: yOffset, width: size, height: size)
    }
}

/// Converts losslessly between plain text containing Tieba emoticon tokens and
/// NSAttributedString containing inline EmoticonTextAttachments.
enum EmoticonStringCodec {
    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"#\(([^)]+)\)|\(#([^)]+)\)|\[([^\]\n]{1,12})\]"#,
        options: []
    )

    static func decodeToAttributedString(
        text: String,
        font: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        guard text.isEmpty == false, let regex = tokenRegex else {
            return NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: textColor
            ])
        }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )
        guard matches.isEmpty == false else {
            return NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: textColor
            ])
        }

        let result = NSMutableAttributedString()
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                let textRange = NSRange(location: cursor, length: match.range.location - cursor)
                let textValue = nsText.substring(with: textRange)
                result.append(NSAttributedString(string: textValue, attributes: [
                    .font: font,
                    .foregroundColor: textColor
                ]))
            }

            let rawToken = nsText.substring(with: match.range)
            var tokenName: String?
            for i in 1..<match.numberOfRanges {
                let range = match.range(at: i)
                if range.location != NSNotFound {
                    tokenName = nsText.substring(with: range)
                    break
                }
            }

            if let name = tokenName, let imageName = TiebaEmoticon.imageName(for: name) {
                let image = TiebaEmoticon.cachedImage(for: imageName) ?? placeholderImage(for: name, font: font)
                let attachment = EmoticonTextAttachment(
                    token: rawToken,
                    imageName: imageName,
                    image: image,
                    font: font
                )
                let attr = NSMutableAttributedString(attachment: attachment)
                attr.addAttributes([
                    .font: font,
                    .foregroundColor: textColor
                ], range: NSRange(location: 0, length: attr.length))
                result.append(attr)
            } else {
                result.append(NSAttributedString(string: rawToken, attributes: [
                    .font: font,
                    .foregroundColor: textColor
                ]))
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            let tail = nsText.substring(from: cursor)
            result.append(NSAttributedString(string: tail, attributes: [
                .font: font,
                .foregroundColor: textColor
            ]))
        }

        return result
    }

    static func encodeToPlainText(from attributedString: NSAttributedString) -> String {
        var plain = ""
        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? EmoticonTextAttachment {
                plain.append(attachment.token)
            } else {
                plain.append((attributedString.string as NSString).substring(with: range))
            }
        }
        return plain
    }

    /// Converts any unformatted emoticon tokens inside the attributed string into attachments in-place.
    /// Returns true if any replacement took place.
    static func formatInlineTokens(
        in attributedString: NSMutableAttributedString,
        font: UIFont,
        textColor: UIColor
    ) -> Bool {
        guard let regex = tokenRegex else { return false }
        let currentString = attributedString.string
        let nsString = currentString as NSString
        let matches = regex.matches(
            in: currentString,
            options: [],
            range: NSRange(location: 0, length: nsString.length)
        )
        guard matches.isEmpty == false else { return false }

        var changed = false
        // Iterate backwards so indices remain valid.
        for match in matches.reversed() {
            // Verify that this range does not already contain an attachment.
            var hasAttachment = false
            attributedString.enumerateAttribute(.attachment, in: match.range, options: []) { value, _, stop in
                if value != nil {
                    hasAttachment = true
                    stop.pointee = true
                }
            }
            if hasAttachment { continue }

            let rawToken = nsString.substring(with: match.range)
            var tokenName: String?
            for i in 1..<match.numberOfRanges {
                let range = match.range(at: i)
                if range.location != NSNotFound {
                    tokenName = nsString.substring(with: range)
                    break
                }
            }

            guard let name = tokenName, let imageName = TiebaEmoticon.imageName(for: name) else {
                continue
            }

            let image = TiebaEmoticon.cachedImage(for: imageName) ?? placeholderImage(for: name, font: font)
            let attachment = EmoticonTextAttachment(
                token: rawToken,
                imageName: imageName,
                image: image,
                font: font
            )
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttributes([
                .font: font,
                .foregroundColor: textColor
            ], range: NSRange(location: 0, length: replacement.length))
            attributedString.replaceCharacters(in: match.range, with: replacement)
            changed = true
        }
        return changed
    }

    private static func placeholderImage(for name: String, font: UIFont) -> UIImage {
        let size = CGSize(width: ceil(font.lineHeight), height: ceil(font.lineHeight))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
            UIColor.systemGray5.setFill()
            path.fill()
        }
    }
}

/// Allows parent view to command insertion of emoticons into the active text editor.
@MainActor
final class EmoticonTextEditorController: ObservableObject {
    var insertEmoticonHandler: ((_ token: String, _ imageName: String) -> Void)?

    func insertEmoticon(token: String, imageName: String) {
        insertEmoticonHandler?(token, imageName)
    }
}

/// A SwiftUI wrapper over UITextView that displays Tieba emoticons as inline rendered images
/// while binding to a plain string representation for network transmission and draft storage.
struct EmoticonTextEditor: UIViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>?
    var controller: EmoticonTextEditorController?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = UIColor.label
        textView.tintColor = UIColor.tintColor
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 4
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        context.coordinator.textView = textView
        context.coordinator.setupArtworkObserver()

        controller?.insertEmoticonHandler = { [weak coordinator = context.coordinator] token, imageName in
            coordinator?.insertEmoticon(token: token, imageName: imageName)
        }

        let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
        let color = textView.textColor ?? UIColor.label
        textView.attributedText = EmoticonStringCodec.decodeToAttributedString(
            text: text,
            font: font,
            textColor: color
        )

        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller?.insertEmoticonHandler = { [weak coordinator = context.coordinator] token, imageName in
            coordinator?.insertEmoticon(token: token, imageName: imageName)
        }

        // Avoid modifying the attributed string while the user is actively typing in IME
        if uiView.markedTextRange != nil {
            return
        }

        let currentPlainText = EmoticonStringCodec.encodeToPlainText(from: uiView.attributedText)
        if currentPlainText != text {
            let font = uiView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let color = uiView.textColor ?? UIColor.label
            let previousRange = uiView.selectedRange
            let newAttributed = EmoticonStringCodec.decodeToAttributedString(
                text: text,
                font: font,
                textColor: color
            )
            uiView.attributedText = newAttributed

            // Restore selection within bounds
            let newLength = newAttributed.length
            if previousRange.location <= newLength {
                uiView.selectedRange = previousRange
            } else {
                uiView.selectedRange = NSRange(location: newLength, length: 0)
            }
        }

        // Handle focus state sync
        if let isFocused = isFocused?.wrappedValue {
            if isFocused && !uiView.isFirstResponder && uiView.window != nil {
                DispatchQueue.main.async {
                    uiView.becomeFirstResponder()
                }
            } else if !isFocused && uiView.isFirstResponder {
                DispatchQueue.main.async {
                    uiView.resignFirstResponder()
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EmoticonTextEditor
        weak var textView: UITextView?
        private var notificationToken: NSObjectProtocol?
        private var isInternalUpdating = false

        init(_ parent: EmoticonTextEditor) {
            self.parent = parent
            super.init()
        }

        deinit {
            if let notificationToken {
                NotificationCenter.default.removeObserver(notificationToken)
            }
        }

        func setupArtworkObserver() {
            notificationToken = NotificationCenter.default.addObserver(
                forName: TiebaEmoticonArtwork.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleArtworkDidChange(notification)
            }
            Task(priority: .utility) {
                for entry in ContentComposerEmoticonCatalog.entries {
                    _ = TiebaEmoticon.cachedImage(for: entry.imageName)
                }
            }
        }

        private func handleArtworkDidChange(_ notification: Notification) {
            guard let textView else { return }
            let imageNames = TiebaEmoticonArtwork.imageNames(from: notification)
            guard imageNames.isEmpty == false else { return }

            let attributed = textView.attributedText ?? NSAttributedString()
            var needsLayout = false

            attributed.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: attributed.length),
                options: []
            ) { value, _, _ in
                if let attachment = value as? EmoticonTextAttachment,
                   imageNames.contains(attachment.imageName) {
                    if let image = TiebaEmoticon.cachedImage(for: attachment.imageName) {
                        attachment.image = image
                        needsLayout = true
                    }
                }
            }

            if needsLayout {
                textView.setNeedsDisplay()
                textView.layoutManager.invalidateDisplay(
                    forCharacterRange: NSRange(location: 0, length: attributed.length)
                )
            }
        }

        func insertEmoticon(token: String, imageName: String) {
            guard let textView else {
                parent.text = ContentComposerPolicy.appendingEmoticon(token, to: parent.text)
                return
            }

            let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let color = textView.textColor ?? UIColor.label
            let image = TiebaEmoticon.cachedImage(for: imageName)
            let attachment = EmoticonTextAttachment(
                token: token,
                imageName: imageName,
                image: image,
                font: font
            )

            let attachmentString = NSMutableAttributedString(attachment: attachment)
            attachmentString.addAttributes([
                .font: font,
                .foregroundColor: color
            ], range: NSRange(location: 0, length: attachmentString.length))

            let selectedRange = textView.selectedRange
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)

            if selectedRange.location != NSNotFound && selectedRange.location <= mutable.length {
                mutable.replaceCharacters(in: selectedRange, with: attachmentString)
                textView.attributedText = mutable
                let nextCursor = selectedRange.location + attachmentString.length
                textView.selectedRange = NSRange(location: min(nextCursor, mutable.length), length: 0)
            } else {
                mutable.append(attachmentString)
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: mutable.length, length: 0)
            }

            let plain = EmoticonStringCodec.encodeToPlainText(from: textView.attributedText)
            parent.text = plain
        }

        func textViewDidChange(_ textView: UITextView) {
            guard isInternalUpdating == false else { return }
            if textView.markedTextRange != nil { return }

            isInternalUpdating = true
            defer { isInternalUpdating = false }

            let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
            let color = textView.textColor ?? UIColor.label

            // Automatically format freshly pasted or typed emoticon tokens (e.g. #(滑稽))
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            let previousSelectedRange = textView.selectedRange
            let formatted = EmoticonStringCodec.formatInlineTokens(
                in: mutable,
                font: font,
                textColor: color
            )

            if formatted {
                textView.attributedText = mutable
                // Re-position selection safely
                if previousSelectedRange.location <= mutable.length {
                    textView.selectedRange = previousSelectedRange
                } else {
                    textView.selectedRange = NSRange(location: mutable.length, length: 0)
                }
            }

            let plain = EmoticonStringCodec.encodeToPlainText(from: textView.attributedText)
            parent.text = plain
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if parent.isFocused?.wrappedValue == false {
                parent.isFocused?.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused?.wrappedValue == true {
                parent.isFocused?.wrappedValue = false
            }
        }
    }
}


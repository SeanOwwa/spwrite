/// Presentation layer: [AiPanelView], the right-hand sidebar that hosts the
/// on-device AI writing assistant for the open project. It is the peer of
/// [CharacterPanelView] and reuses its structure — a header, a divider, a
/// scrollable body, and (here) a message input row.
///
/// It observes [AiAssistantState] via `provider` and renders the project's
/// conversation as a scrollable list of user/assistant turns, with a message
/// input row that sends the typed text and clears the field. All colors and
/// text are drawn from [AppPalette] so the panel matches the dark navy theme
/// (Req 2.1, 2.9).
///
/// Task 7.2 fleshes out the conversation: user and assistant turns render with
/// clear affordances (system/priming turns are hidden from the visible list); a
/// typing indicator appears while a reply is generating but no token has yet
/// streamed (Req 2.3, 2.4); the send control is disabled while generating and
/// swaps to a stop control that cancels the in-flight reply (Req 2.3, 2.6); the
/// list auto-scrolls to the latest turn as content arrives, including streaming
/// deltas (Req 2.7); and grounded assistant answers show a lightweight source
/// hint (Req 5.4).
///
/// Task 14.1 (feature 3.6) adds a non-blocking indexing/semantic status strip
/// ([_IndexingStatusStrip]) that sits between the header and the conversation
/// body. It observes the project-scoped [IndexingState] via `provider` — the
/// same way this view observes [AiAssistantState] — and surfaces the one-time
/// embedding-model download prompt/progress, the background reindex progress
/// ("X of Y" while building), a ready/idle state, and a recoverable transient
/// error. Every color and text style is drawn from [AppPalette] (Req 10.1) and
/// nothing in the strip disables the conversation or the input row, so chat and
/// keyword grounding stay fully usable while the model downloads or the index
/// rebuilds (Req 9.1, 9.6). Because the `IndexingState` provider is wired by the
/// composition root in task 16 (not yet landed), the strip reads the state as a
/// *nullable* dependency (`context.watch<IndexingState?>()`) and renders nothing
/// when it is absent — keeping this change self-contained and crash-free.
///
/// Task 7.3 adds the model-readiness surfaces: [_buildBody] branches on
/// `modelStatus` to show the one-time download prompt (approximate size,
/// on-device/free framing, license) when the Model Asset is absent (Req 3.1), a
/// non-dismissible progress surface while it downloads (Req 3.2), and a friendly
/// error/retry surface if it fails (Req 3.5) — the chat body only renders once
/// the model is ready. The panel probes readiness once on open via
/// `ensureModelReady` (no network). A small dismissible error banner sits above
/// the input row when a reply generation fails (Req 2.5). The non-blocking
/// offline banner slots above the body (task 7.4).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/ai/chat_message.dart';
import '../domain/ai/connectivity_probe.dart';
import '../domain/ai/model_catalog.dart';
import '../state/ai_assistant_state.dart';
import '../state/indexing_state.dart';
import '../theme/app_theme.dart';
import 'panel_header.dart';

/// The right-hand AI Panel sidebar. [onClose] hides the panel (the enclosing
/// editor owns the open/closed state, exactly as it does for the Character
/// Panel).
class AiPanelView extends StatefulWidget {
  /// Invoked when the user taps the panel's close control.
  final VoidCallback onClose;

  const AiPanelView({super.key, required this.onClose});

  @override
  State<AiPanelView> createState() => _AiPanelViewState();
}

class _AiPanelViewState extends State<AiPanelView> {
  /// Backs the message input field; read and cleared on send.
  final TextEditingController _inputController = TextEditingController();

  /// Drives the conversation list so it can auto-scroll to the latest turn as
  /// new content arrives (Req 2.7). Basic auto-scroll lives here; richer
  /// behaviour is refined in task 7.2.
  final ScrollController _scrollController = ScrollController();

  /// Guards the one-shot init (readiness probe + persisted-conversation load)
  /// so the panel calls into the state exactly once when it first opens.
  bool _probedModel = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Run the panel's one-shot init once when it first mounts. Read (not watch)
    // the provider here and defer to the next frame so we don't call into the
    // notifier during build.
    if (_probedModel) return;
    _probedModel = true;
    final AiAssistantState state = context.read<AiAssistantState>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Probe the Model Asset's presence, so the body resolves the initial
      // `absent` status to either `ready` (cached fast-path, Req 3.6) or
      // `absent` (surface the one-time download prompt, Req 3.1).
      // `ensureModelReady` touches no network.
      state.ensureModelReady();
      // Replay any persisted conversation for this project (Req 9.3, optional).
      // A no-op when cross-launch persistence is disabled (no repository
      // injected), so the panel behaves exactly as before when it is off.
      state.loadPersistedConversation();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Sends the currently typed message and clears the field. Empty/whitespace
  /// input is rejected by the state layer (Req 2.8); the send control is also
  /// disabled while it is empty or while a reply is generating, so this is
  /// defensive.
  void _handleSend(AiAssistantState state) {
    final String text = _inputController.text;
    if (text.trim().isEmpty) return;
    if (state.generationStatus == GenerationStatus.generating) return;
    state.sendMessage(text);
    _inputController.clear();
    _scrollToLatest();
  }

  /// Scrolls the conversation to its most recent turn, if the list is attached.
  /// Deferred to the next frame so the just-appended (or just-grown) turn is
  /// laid out before we measure the scroll extent (Req 2.7).
  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AiAssistantState state = context.watch<AiAssistantState>();

    // Observe the semantic-index state the same way we observe
    // [AiAssistantState] — via `provider` — so the panel rebuilds as indexing
    // progresses (Req 9.1). It is read as a *nullable* dependency on purpose:
    // the composition root wires the `IndexingState` provider in task 16
    // (16.3), which has not landed yet, so until then the lookup returns `null`
    // and the strip simply renders nothing. This keeps 14.1 self-contained and
    // non-crashing — the panel and chat work identically with or without the
    // provider present, honouring the "never blocks chat" contract (Req 9.1).
    final IndexingState? indexing = context.watch<IndexingState?>();

    // Keep the latest turn in view as new turns arrive and as streaming deltas
    // grow the last bubble. The panel rebuilds on every `notifyListeners`, so
    // scheduling a post-frame scroll here follows the conversation as it
    // streams (Req 2.7).
    _scrollToLatest();

    return Container(
      color: AppPalette.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(context, state),
          // Non-blocking offline hint: shown only when connectivity is
          // definitively offline. `unknown` never asserts offline, so a wrong
          // or pending check degrades gracefully rather than nagging the writer
          // (Req 4.2, 4.4). The banner is purely informational — it does not
          // disable the input or the conversation, which stay fully usable
          // offline (Req 4.3).
          if (state.connectivity == ConnectivityStatus.offline)
            const _OfflineBanner(),
          // Non-blocking semantic-index status strip: surfaces the one-time
          // embedding-model download, the reindex progress, ready/idle, and a
          // recoverable transient error — all drawn from [AppPalette] and none
          // of which disable the conversation or the input below (Req 9.1, 9.6,
          // 10.1). Rendered only when the `IndexingState` provider is wired.
          if (indexing != null) _IndexingStatusStrip(state: indexing),
          Expanded(child: _buildBody(context, state)),
          const Divider(height: 1, thickness: 1, color: AppPalette.hairline),
          // Recoverable chat errors: a failed reply (Req 2.5), or a "New chat"
          // whose saved history couldn't be removed (status stays idle). Model
          // download errors are shown by their own surface in the body.
          if (state.transientError != null &&
              (state.generationStatus == GenerationStatus.error ||
                  state.modelStatus == ModelStatus.ready))
            _GenerationErrorBanner(
              message: state.transientError!,
              onDismiss: state.clearTransientError,
            ),
          _buildInputRow(context, state),
        ],
      ),
    );
  }

  /// Asks the writer to confirm, then clears the conversation so the assistant
  /// starts fresh. Cancelling (or dismissing the dialog) keeps the chat.
  Future<void> _confirmNewChat(AiAssistantState state) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Start a new chat?'),
          content: const Text(
            'This clears the current conversation.',
            style: TextStyle(color: AppPalette.textPrimary),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppPalette.error),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    _inputController.clear();
    await state.clearConversation();
  }

  /// The panel header: an assistant icon, a "SpwriteBot" title, a "New chat"
  /// control that clears the conversation (disabled while it is empty), and a
  /// close control (Req 2.1).
  Widget _buildHeader(BuildContext context, AiAssistantState state) {
    return PanelHeader(
      icon: Icons.auto_awesome,
      title: 'SpwriteBot',
      subtitle: 'Runs on this device',
      actions: <Widget>[
        IconButton(
          tooltip: 'New chat',
          icon: const Icon(
            Icons.add_comment_outlined,
            semanticLabel: 'Start a new chat',
          ),
          color: AppPalette.textSecondary,
          disabledColor: AppPalette.outline,
          onPressed: state.isEmpty ? null : () => _confirmNewChat(state),
        ),
        IconButton(
          tooltip: 'Close panel',
          icon: const Icon(Icons.close, color: AppPalette.textSecondary),
          onPressed: widget.onClose,
        ),
      ],
    );
  }

  /// The panel body, which reflects the Local Model's readiness
  /// ([AiAssistantState.modelStatus]) before the conversation itself:
  ///
  /// - [ModelStatus.downloading]: a non-dismissible progress surface with the
  ///   one-time download's progress (Req 3.2).
  /// - [ModelStatus.absent]: the one-time download prompt — approximate size,
  ///   on-device/free framing, and license — with a Download button (Req 3.1).
  /// - [ModelStatus.failed]: a friendly error/retry surface carrying the
  ///   state's recoverable message and a Retry button (Req 3.5, 2.5); the rest
  ///   of the app stays usable.
  /// - [ModelStatus.ready]: the chat body — the empty-state prompt or the
  ///   conversation list.
  ///
  /// Task 7.4 slots the non-blocking offline banner above the conversation.
  Widget _buildBody(BuildContext context, AiAssistantState state) {
    switch (state.modelStatus) {
      case ModelStatus.downloading:
        return _ModelDownloadingSurface(
          progress: state.downloadProgress,
          receivedBytes: state.downloadReceivedBytes,
          totalBytes: state.downloadTotalBytes,
          activity: state.downloadActivity,
          connectivity: state.connectivity,
          onRetry: state.downloadModel,
        );
      case ModelStatus.absent:
        return _ModelDownloadPrompt(
          model: state.model,
          onDownload: state.downloadModel,
        );
      case ModelStatus.failed:
        return _ModelDownloadFailedSurface(
          message: state.transientError,
          onRetry: state.downloadModel,
        );
      case ModelStatus.ready:
        return _buildChatBody(context, state);
    }
  }

  /// The chat body shown once the Model Asset is ready: the empty-state prompt
  /// when there are no turns yet, otherwise the scrollable conversation list.
  Widget _buildChatBody(BuildContext context, AiAssistantState state) {
    if (state.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.auto_awesome_outlined,
                  size: 48, color: AppPalette.textSecondary),
              SizedBox(height: 12),
              Text(
                'Ask the assistant about your story.\nIt reads your project '
                'and runs entirely on this device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppPalette.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return _buildMessageList(context, state);
  }

  /// The scrollable list of conversation turns (oldest first).
  ///
  /// System/priming turns are hidden — they steer the assistant but are not
  /// part of the writer-facing conversation, so only user and assistant turns
  /// render (Req 2.2). While a reply is generating and no token has yet
  /// streamed into the assistant placeholder (its text is still empty), an
  /// animated typing indicator is appended so the writer sees the assistant is
  /// working; once the first delta arrives the partial text shows in its place
  /// (Req 2.3, 2.4).
  Widget _buildMessageList(BuildContext context, AiAssistantState state) {
    // Only the writer-facing turns render; system/priming turns stay hidden.
    final List<ChatMessage> visible = state.messages
        .where((ChatMessage m) => m.role != ChatRole.system)
        .toList(growable: false);

    // Show the typing indicator while generating and the streamed assistant
    // turn is still empty (a placeholder before the first delta), or there is
    // no assistant turn yet at all.
    final bool lastIsEmptyAssistant = visible.isNotEmpty &&
        visible.last.role == ChatRole.assistant &&
        visible.last.text.isEmpty;
    final bool showTyping =
        state.generationStatus == GenerationStatus.generating &&
            (visible.isEmpty ||
                lastIsEmptyAssistant ||
                visible.last.role == ChatRole.user);

    // If the last visible turn is an empty assistant placeholder, drop it from
    // the rendered list — the typing indicator stands in for it until the
    // first token arrives, avoiding an empty bubble beside the dots.
    final List<ChatMessage> rendered = (showTyping && lastIsEmptyAssistant)
        ? visible.sublist(0, visible.length - 1)
        : visible;

    final int itemCount = rendered.length + (showTyping ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (showTyping && index == rendered.length) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: _TypingIndicator(),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _MessageBubble(message: rendered[index]),
        );
      },
    );
  }

  /// The message input row: a text field and a send/stop control.
  ///
  /// While a reply is generating, send is disabled and the control swaps to a
  /// stop button that cancels the in-flight reply (Req 2.3, 2.6). When idle,
  /// send is enabled only once the field holds non-whitespace text (empty input
  /// is also rejected by the state layer, Req 2.8).
  Widget _buildInputRow(BuildContext context, AiAssistantState state) {
    final bool generating =
        state.generationStatus == GenerationStatus.generating;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm + 2,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _inputController,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              style: const TextStyle(color: AppPalette.textPrimary),
              decoration: const InputDecoration(
                hintText: 'Message the assistant',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _handleSend(state),
            ),
          ),
          const SizedBox(width: 8),
          if (generating)
            IconButton(
              tooltip: 'Stop generating',
              icon: const Icon(Icons.stop),
              color: AppPalette.secondary,
              onPressed: state.cancelGeneration,
            )
          else
            IconButton(
              tooltip: 'Send',
              icon: const Icon(Icons.send),
              color: AppPalette.onPrimary,
              disabledColor: AppPalette.textSecondary,
              style: const ButtonStyle(
                backgroundColor: WidgetStateProperty<Color?>.fromMap(
                  <WidgetStatesConstraint, Color?>{
                    WidgetState.disabled: AppPalette.surfaceVariant,
                    WidgetState.any: AppPalette.primary,
                  },
                ),
              ),
              onPressed: _inputController.text.trim().isEmpty
                  ? null
                  : () => _handleSend(state),
            ),
        ],
      ),
    );
  }
}

/// A single conversation turn rendered as a bubble: the writer's turns align
/// right on the primary accent; the assistant's align left on the raised
/// surface variant, prefixed with a small assistant avatar so the two speakers
/// are visually distinct (Req 2.2). Grounded assistant answers carry a
/// lightweight source hint below the text (Req 5.4).
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.role == ChatRole.user;
    final Color bubbleColor =
        isUser ? AppPalette.primary : AppPalette.surfaceVariant;
    final Color textColor =
        isUser ? AppPalette.onPrimary : AppPalette.textPrimary;

    // Speech-bubble corners: the corner nearest the speaker is tightened.
    const Radius round = Radius.circular(AppStyle.radiusMedium + 2);
    const Radius tight = Radius.circular(AppSpacing.xs);
    final Widget bubble = Container(
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: isUser ? round : tight,
          topRight: isUser ? tight : round,
          bottomLeft: round,
          bottomRight: round,
        ),
        border: isUser ? null : Border.all(color: AppPalette.hairline),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message.text,
            style: TextStyle(color: textColor, fontSize: 14, height: 1.4),
          ),
          if (!isUser && message.sources.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            _SourceHint(sources: message.sources),
          ],
        ],
      ),
    );

    if (isUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }

    // Assistant turns lead with a small avatar so the speaker is clear.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 8),
          child:
              Icon(Icons.auto_awesome, size: 18, color: AppPalette.secondary),
        ),
        Flexible(child: bubble),
      ],
    );
  }
}

/// A lightweight "Sources: …" hint shown below a grounded assistant answer,
/// naming the Project-Context material the reply drew from (Req 5.4). The list
/// is already de-duplicated by the state layer.
class _SourceHint extends StatelessWidget {
  final List<ChatMessageSource> sources;

  const _SourceHint({required this.sources});

  @override
  Widget build(BuildContext context) {
    final String names =
        sources.map((ChatMessageSource s) => s.title).join(', ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 1, right: 4),
          child: Icon(Icons.menu_book_outlined,
              size: 13, color: AppPalette.textSecondary),
        ),
        Expanded(
          child: Text(
            'Sources: $names',
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// An animated three-dot "assistant is typing" indicator shown while a reply is
/// generating but no token has streamed yet (Req 2.3, 2.4). Rendered in an
/// assistant-styled bubble so it reads as a turn the assistant is composing.
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 8),
          child:
              Icon(Icons.auto_awesome, size: 18, color: AppPalette.secondary),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppPalette.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppPalette.outline),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Semantics(
            label: 'Assistant is typing',
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _dot(0),
                    const SizedBox(width: 5),
                    _dot(1),
                    const SizedBox(width: 5),
                    _dot(2),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// One pulsing dot whose opacity is phase-shifted by [index] so the three
  /// dots animate in sequence.
  Widget _dot(int index) {
    // Stagger each dot by a third of the cycle; opacity eases 0.3 → 1 → 0.3.
    final double phase = (_controller.value + index / 3) % 1.0;
    final double wave = (phase < 0.5) ? phase * 2 : (1 - phase) * 2;
    final double opacity = 0.3 + 0.7 * wave;
    return Opacity(
      opacity: opacity,
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: AppPalette.textSecondary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Formats a byte count as an approximate, human-friendly download size for the
/// one-time model prompt (Req 3.1) — e.g. `~0.9 GB` or `~640 MB`. Uses decimal
/// (1000-based) units so the figure matches how download sizes are usually
/// quoted to users, and keeps a single significant fractional digit for GB.
/// Formats a byte count as a compact human-readable size (e.g. `12.3 MB`,
/// `0.9 GB`, `640 KB`) for the live download hint (Req 3.2). Uses decimal
/// (1000-based) units to match how download sizes are commonly quoted.
String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const int kb = 1000;
  const int mb = 1000 * 1000;
  const int gb = 1000 * 1000 * 1000;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

String _formatApproxSize(int bytes) {
  if (bytes <= 0) return 'unknown size';
  const int mb = 1000 * 1000;
  const int gb = 1000 * 1000 * 1000;
  if (bytes >= gb) {
    final double value = bytes / gb;
    return '~${value.toStringAsFixed(1)} GB';
  }
  final double value = bytes / mb;
  return '~${value.round()} MB';
}

/// The centered progress surface shown while the one-time Model Asset download
/// is in flight ([ModelStatus.downloading], Req 3.2, 3.4).
///
/// Shows a title, a linear progress bar (determinate once a size is known,
/// indeterminate while it is still starting), a human-readable "X of Y" byte
/// hint with the percentage, and a live activity line so the writer can tell
/// the download is still working. If no new bytes arrive for a while
/// ([DownloadActivity.stalled]) it swaps to a clear "seems stuck" warning that
/// names the likely cause (connectivity) and offers a Retry — so a silent
/// mid-download drop is obvious and recoverable rather than an ambiguous,
/// frozen-looking bar (Req 3.4).
class _ModelDownloadingSurface extends StatelessWidget {
  final double progress;
  final int receivedBytes;
  final int? totalBytes;
  final DownloadActivity activity;
  final ConnectivityStatus connectivity;
  final VoidCallback onRetry;

  const _ModelDownloadingSurface({
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
    required this.activity,
    required this.connectivity,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final bool determinate = progress > 0;
    final int percent = (progress.clamp(0.0, 1.0) * 100).round();
    final bool stalled = activity == DownloadActivity.stalled;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Icon(
              stalled
                  ? Icons.cloud_off_outlined
                  : Icons.cloud_download_outlined,
              size: 44,
              color: stalled ? AppPalette.error : AppPalette.secondary,
            ),
            const SizedBox(height: 16),
            const Text(
              'Downloading the assistant model',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'This one-time download runs in the background. The assistant '
              'works fully offline once it finishes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: AppStyle.pillRadius,
              child: LinearProgressIndicator(
                // While stalled, freeze at the last known fraction (or show the
                // determinate bar) rather than the animated indeterminate sweep,
                // so the "moving" bar doesn't contradict the "stuck" message.
                value:
                    (determinate || stalled) ? progress.clamp(0.0, 1.0) : null,
                minHeight: 8,
                backgroundColor: AppPalette.surfaceVariant,
                valueColor: AlwaysStoppedAnimation<Color>(
                  stalled ? AppPalette.error : AppPalette.primary,
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Byte hint: "12.3 MB of 0.9 GB · 34%" (or a plain percent / starting
            // label when the size or progress is unknown).
            Text(
              _progressLabel(determinate, percent),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            // The live activity line: reassures while active, warns while
            // stalled (Req 3.4).
            _DownloadActivityLine(
              stalled: stalled,
              connectivity: connectivity,
            ),
            if (stalled) ...<Widget>[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry download'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Builds the "X of Y · NN%" progress label, degrading gracefully when the
  /// total size or the fraction is not yet known.
  String _progressLabel(bool determinate, int percent) {
    final int? total = totalBytes;
    if (total != null && total > 0) {
      return '${_formatBytes(receivedBytes)} of ${_formatBytes(total)}'
          ' · $percent%';
    }
    if (receivedBytes > 0) {
      return '${_formatBytes(receivedBytes)} downloaded';
    }
    return determinate ? '$percent%' : 'Starting download…';
  }
}

/// A one-line status beneath the progress bar: a reassuring "receiving data…"
/// while the download is progressing, or a clear "seems stuck — check your
/// connection" warning (with the current connectivity) once it stalls (Req 3.4).
class _DownloadActivityLine extends StatelessWidget {
  final bool stalled;
  final ConnectivityStatus connectivity;

  const _DownloadActivityLine({
    required this.stalled,
    required this.connectivity,
  });

  @override
  Widget build(BuildContext context) {
    if (stalled) {
      final bool offline = connectivity == ConnectivityStatus.offline;
      final String message = offline
          ? "You appear to be offline, so the download can't continue. "
              'Reconnect and retry.'
          : "This is taking longer than expected and may be stuck. "
              'Check your internet connection, then retry.';
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.warning_amber_rounded,
              size: 15, color: AppPalette.error),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppPalette.error,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      );
    }

    // Active: a small animated pulse + "receiving data…" so the writer can see
    // it is alive even between percentage ticks.
    return const Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppPalette.secondary),
          ),
        ),
        SizedBox(width: 8),
        Text(
          'Receiving data…',
          style: TextStyle(color: AppPalette.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

/// The one-time download prompt shown when the Model Asset is not yet cached
/// ([ModelStatus.absent], Req 3.1).
///
/// Explains that the model is downloaded once, states the approximate size,
/// makes clear it then runs on-device and free, notes the open license, and
/// offers a Download button that starts the confirm-gated download
/// ([AiAssistantState.downloadModel]).
class _ModelDownloadPrompt extends StatelessWidget {
  final ModelMetadata model;
  final VoidCallback onDownload;

  const _ModelDownloadPrompt({required this.model, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Icon(Icons.auto_awesome_outlined,
                size: 48, color: AppPalette.secondary),
            const SizedBox(height: 16),
            const Text(
              'Download the assistant model',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'The assistant runs entirely on this device. The first time you '
              'use it, it downloads its model once '
              '(${_formatApproxSize(model.sizeBytes)}). After that it works '
              'fully offline, with no account and no cost.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            _PromptFactRow(
              icon: Icons.sd_storage_outlined,
              label: 'One-time download, ${_formatApproxSize(model.sizeBytes)}',
            ),
            const SizedBox(height: 8),
            const _PromptFactRow(
              icon: Icons.wifi_off_outlined,
              label: 'Runs on-device and free — offline after this',
            ),
            const SizedBox(height: 8),
            _PromptFactRow(
              icon: Icons.verified_outlined,
              label: 'Open license: ${model.licenseName}',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download),
              label: const Text('Download'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single labelled fact row in the download prompt — an accent icon beside a
/// short line of secondary text.
class _PromptFactRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _PromptFactRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: AppPalette.secondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 13,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// The friendly error / retry surface shown when the one-time download failed
/// ([ModelStatus.failed], Req 3.5, 2.5).
///
/// Surfaces the state's recoverable [message] (which already carries offline vs.
/// generic wording) and a Retry button that re-runs the download. No corrupt
/// asset is left behind by a failed download, so retrying is safe. The rest of
/// the app is unaffected — this surface lives inside the panel.
class _ModelDownloadFailedSurface extends StatelessWidget {
  final String? message;
  final VoidCallback onRetry;

  const _ModelDownloadFailedSurface({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 44, color: AppPalette.error),
            const SizedBox(height: 16),
            const Text(
              "The model download didn't finish",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message ??
                  'The one-time model download did not complete. Please try '
                      'again.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact, non-blocking offline strip shown below the header when the
/// device is offline ([ConnectivityStatus.offline], Req 4.2). It makes clear
/// that internet search is unavailable while reassuring the writer that chat
/// and project search still work (Req 4.3). It is informational only — it never
/// disables the input or the conversation, and it is not shown when online or
/// when connectivity is `unknown` so a wrong or pending check degrades
/// gracefully (Req 4.4).
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppPalette.surfaceVariant,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: 1, right: 8),
            child: Icon(Icons.wifi_off_outlined,
                size: 16, color: AppPalette.secondary),
          ),
          Expanded(
            child: Text(
              "You're offline — internet search is unavailable. Chat and "
              'project search still work.',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small, dismissible error banner shown just above the input row when a
/// reply generation failed ([GenerationStatus.error], Req 2.5). It surfaces the
/// recoverable [message] the state set and a dismiss control that clears it via
/// [AiAssistantState.clearTransientError]; the conversation is retained and the
/// input stays usable so the writer can simply send again.
class _GenerationErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _GenerationErrorBanner({
    required this.message,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppPalette.surfaceVariant,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 1, right: 8),
            child: Icon(Icons.error_outline, size: 18, color: AppPalette.error),
          ),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16),
            color: AppPalette.textSecondary,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// A compact, non-blocking status strip surfacing the semantic-index lifecycle
/// between the panel header and the conversation body (Req 9.1, 9.6, 10.1).
///
/// It observes the project-scoped [IndexingState] and renders exactly one of a
/// small set of states, in priority order:
///
/// 1. The embedding model is absent — a one-time download prompt with a
///    confirm-to-download action ([IndexingState.downloadEmbeddingModel],
///    Req 3.2).
/// 2. The embedding model is downloading — a slim progress line with an "X of
///    Y" byte hint (Req 3.2).
/// 3. The embedding model download failed — a recoverable message with a Retry
///    action (Req 3.4, 3.5).
/// 4. A reindex is building — a slim progress line with the "X of Y" source
///    count (Req 9.2, 9.6).
/// 5. A recoverable transient error (e.g. a background indexing hiccup) — a
///    non-blocking notice (Req 7.4).
/// 6. Ready — a brief "semantic search ready" confirmation (Req 9.6).
///
/// When the index is simply idle with nothing to say (no model prompt, not
/// building, ready-but-unremarkable, no error) the strip collapses to nothing so
/// it never nags. Crucially, **none** of these states disable the conversation
/// or the message input — the strip sits above the body and is purely
/// informational, so the writer keeps chatting (with keyword / chat-only
/// grounding) while the model downloads or the index rebuilds (Req 9.1). Every
/// color and text style is drawn from [AppPalette] to match the 3.5 panel
/// (Req 10.1).
class _IndexingStatusStrip extends StatelessWidget {
  final IndexingState state;

  const _IndexingStatusStrip({required this.state});

  @override
  Widget build(BuildContext context) {
    // Priority order: the embedding-model lifecycle first (it gates semantic
    // search at all), then reindex progress, then a transient error, then a
    // ready confirmation. Anything else collapses to nothing.
    final Widget? content = _resolveContent();
    if (content == null) return const SizedBox.shrink();

    return Container(
      color: AppPalette.surfaceVariant,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: content,
    );
  }

  /// Picks the single strip variant to show for the current state, or `null`
  /// when there is nothing worth surfacing (idle with no prompt/progress/error).
  Widget? _resolveContent() {
    switch (state.embeddingModelStatus) {
      case EmbeddingModelStatus.absent:
        return _buildDownloadPrompt();
      case EmbeddingModelStatus.downloading:
        return _buildDownloadProgress();
      case EmbeddingModelStatus.failed:
        return _buildDownloadFailed();
      case EmbeddingModelStatus.unknown:
      case EmbeddingModelStatus.ready:
        // The model is not blocking the strip — fall through to the index
        // status below.
        break;
    }

    // A recoverable indexing error takes precedence over progress/ready so the
    // writer sees the (non-blocking) notice, but it is never fatal.
    if (state.status == IndexStatus.building) {
      return _buildBuildingProgress();
    }
    final String? error = state.transientError;
    if (state.status == IndexStatus.error && error != null) {
      return _buildTransientError(error);
    }
    if (state.transientError != null) {
      return _buildTransientError(state.transientError!);
    }
    if (state.status == IndexStatus.ready) {
      return _buildReady();
    }
    // Idle with nothing to say — collapse.
    return null;
  }

  /// The one-time embedding-model download prompt (Req 3.2): a short line
  /// explaining the on-device/free/one-time framing with a Download action that
  /// starts the confirm-gated download. Non-blocking — chat keeps working with
  /// keyword grounding until it finishes.
  Widget _buildDownloadPrompt() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 8),
          child: Icon(Icons.travel_explore_outlined,
              size: 16, color: AppPalette.secondary),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Enable semantic search across your whole project? It downloads '
                'a small model once (${_formatApproxSize(state.model.sizeBytes)}), '
                'then runs on-device and free.',
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: state.downloadEmbeddingModel,
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Download'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppPalette.primary,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The slim in-flight embedding-model download line (Req 3.2): a title, a
  /// determinate/indeterminate bar, and an "X of Y · NN%" byte hint.
  Widget _buildDownloadProgress() {
    final double progress = state.downloadProgress.clamp(0.0, 1.0);
    final int? total = state.downloadTotalBytes;
    final bool determinate = progress > 0;
    final int percent = (progress * 100).round();
    final String hint = (total != null && total > 0)
        ? '${_formatBytes(state.downloadReceivedBytes)} of '
            '${_formatBytes(total)} · $percent%'
        : (state.downloadReceivedBytes > 0
            ? '${_formatBytes(state.downloadReceivedBytes)} downloaded'
            : 'Starting download…');

    return _ProgressLines(
      icon: Icons.cloud_download_outlined,
      title: 'Downloading the semantic-search model',
      detail: hint,
      value: determinate ? progress : null,
    );
  }

  /// The recoverable embedding-model download failure (Req 3.4, 3.5): the
  /// state's message plus a Retry that re-runs the confirm-gated download.
  Widget _buildDownloadFailed() {
    final String message = state.transientError ??
        'The one-time semantic-search model download did not complete.';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 1, right: 8),
          child: Icon(Icons.error_outline, size: 16, color: AppPalette.error),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                message,
                style: const TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: state.downloadEmbeddingModel,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppPalette.primary,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The background reindex progress line (Req 9.2, 9.6): a title, a
  /// determinate/indeterminate bar, and the "X of Y sources" count. Querying
  /// stays responsive throughout (Req 9.5) — this is a hint, not a gate.
  Widget _buildBuildingProgress() {
    final int total = state.totalSources;
    final int done = state.indexedSources;
    final double progress = state.progress.clamp(0.0, 1.0);
    final String detail = total > 0
        ? '$done of $total sources · ${(progress * 100).round()}%'
        : 'Preparing…';

    return _ProgressLines(
      icon: Icons.travel_explore_outlined,
      title: 'Indexing your project for semantic search',
      detail: detail,
      // Only show a determinate bar once we know the total; otherwise let it
      // sweep so an early "0 of 0" doesn't read as a frozen empty bar.
      value: total > 0 ? progress : null,
    );
  }

  /// A recoverable, non-blocking indexing notice (Req 7.4): something hiccuped
  /// while indexing, the assistant keeps working with keyword grounding, and it
  /// will retry — so this is informational, not an error the writer must act on.
  Widget _buildTransientError(String message) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 1, right: 8),
          child:
              Icon(Icons.info_outline, size: 16, color: AppPalette.secondary),
        ),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  /// A brief "semantic search is ready" confirmation once a build completes
  /// (Req 9.6). Purely informational and low-emphasis.
  Widget _buildReady() {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(top: 1, right: 8),
          child: Icon(Icons.check_circle_outline,
              size: 16, color: AppPalette.secondary),
        ),
        Expanded(
          child: Text(
            'Semantic search ready — the assistant can search your whole '
            'project.',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// A shared two-line progress block used by the indexing strip for both the
/// embedding-model download and the reindex build: an accent icon and title on
/// the first line, a slim [LinearProgressIndicator] (determinate when [value]
/// is non-null, otherwise an indeterminate sweep), and a secondary [detail]
/// caption. All colors come from [AppPalette] (Req 10.1).
class _ProgressLines extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;
  final double? value;

  const _ProgressLines({
    required this.icon,
    required this.title,
    required this.detail,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 16, color: AppPalette.secondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: AppStyle.pillRadius,
          child: LinearProgressIndicator(
            value: value,
            minHeight: 5,
            backgroundColor: AppPalette.surface,
            valueColor: const AlwaysStoppedAnimation<Color>(AppPalette.primary),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          detail,
          style: const TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

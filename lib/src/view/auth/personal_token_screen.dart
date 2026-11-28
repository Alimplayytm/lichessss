import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/auth/auth_diagnostics.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/widgets/feedback.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class const PersonalTokenScreen({super.key}) extends ConsumerStatefulWidget {
  static Route<dynamic> buildRoute() => buildScreenRoute(screen: const PersonalTokenScreen());

  @override
  ConsumerState<PersonalTokenScreen> createState() => _PersonalTokenScreenState();
}

class _PersonalTokenScreenState() extends ConsumerState<PersonalTokenScreen> {
  final _tokenController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void dispose() {
    _tokenController.clear();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .signInWithPersonalToken(_tokenController.text);
      if (!mounted) return;
      _tokenController.clear();
      setState(() => _busy = false);
      // Let PopScope observe canPop=true before closing the route.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } on AuthDiagnosticException catch (error) {
      if (mounted) showSnackBar(context, error.userMessage, type: SnackBarType.error);
    } catch (_) {
      if (mounted) {
        showSnackBar(
          context,
          'Could not complete sign-in. See the app log.',
          type: SnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A read alone does not keep this auto-disposed controller alive across the HTTP request.
    ref.watch(authControllerProvider);
    return PopScope(
      canPop: !_busy,
      child: PlatformScaffold(
        appBar: const PlatformAppBar(title: Text('Sign in with API token')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
          child: AutofillGroup(
            onDisposeAction: AutofillContextAction.cancel,
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Use a new personal API token from your own Lichess account. '
                    'Revoke any token you have shared. Never share your replacement token.',
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => launchUrl(
                            Uri.https('lichess.org', '/account/oauth/token'),
                            mode: LaunchMode.externalApplication,
                          ),
                    child: const Text('Create or revoke a token on lichess.org'),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _tokenController,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [],
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Personal API token'),
                    validator: (input) => RegExp(r'^[A-Za-z0-9_]+$').hasMatch(input?.trim() ?? '')
                        ? null
                        : 'Paste only the token, without a Bearer prefix or spaces.',
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'The token is sent only to lichess.org over HTTPS and stored in secure '
                    'storage on this device. It is not included in app logs. Signing out forgets '
                    'it locally; revoke it on Lichess if it is no longer needed.',
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'This is public API access, not official-client authentication. Some mobile '
                    'features or live games may not support it. Grant only the permissions you need. '
                    'Engine assistance in games against people violates fair-play rules.',
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy ? 'Signing in…' : 'Sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

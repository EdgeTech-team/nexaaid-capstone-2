import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

enum AppButtonVariant {
  /// Main action of a screen (one per screen).
  primary,

  /// Second action next to a primary one.
  secondary,

  /// Low-emphasis filled action, e.g. inside cards.
  tonal,

  /// Every "Donate" action uses this so donors can always find it.
  donate,

  /// Destructive actions: reject, decline, delete.
  danger,

  /// Lowest emphasis: links, "Cancel".
  text,
}

/// The one button to use in new screens.
///
/// ```dart
/// AppButton('Save changes', onPressed: _save, loading: busy, expand: true)
/// ```
/// Do not put an `expand: true` button directly inside a Row; wrap it in
/// Expanded instead.
class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonVariant variant;
  final bool loading;
  final bool expand;
  final bool large;

  const AppButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
    this.variant = AppButtonVariant.primary,
    this.loading = false,
    this.expand = false,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = Size(expand ? double.infinity : 64, large ? 56 : 48);
    final cb = loading ? null : onPressed;

    final content = Builder(
      builder: (ctx) {
        final fg = IconTheme.of(ctx).color;
        if (loading) {
          return SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
          );
        }
        if (icon == null) return Text(label, textAlign: TextAlign.center);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            Gaps.h8,
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        );
      },
    );

    final Widget button = switch (variant) {
      AppButtonVariant.primary => FilledButton(
        onPressed: cb,
        style: FilledButton.styleFrom(minimumSize: size),
        child: content,
      ),
      AppButtonVariant.tonal => FilledButton.tonal(
        onPressed: cb,
        style: FilledButton.styleFrom(minimumSize: size),
        child: content,
      ),
      AppButtonVariant.donate => FilledButton(
        onPressed: cb,
        style: FilledButton.styleFrom(
          minimumSize: size,
          backgroundColor: AppColors.vest,
          foregroundColor: AppColors.vestInk,
        ),
        child: content,
      ),
      AppButtonVariant.danger => FilledButton(
        onPressed: cb,
        style: FilledButton.styleFrom(
          minimumSize: size,
          backgroundColor: cs.error,
          foregroundColor: cs.onError,
        ),
        child: content,
      ),
      AppButtonVariant.secondary => OutlinedButton(
        onPressed: cb,
        style: OutlinedButton.styleFrom(minimumSize: size),
        child: content,
      ),
      AppButtonVariant.text => TextButton(
        onPressed: cb,
        style: TextButton.styleFrom(minimumSize: size),
        child: content,
      ),
    };

    return loading
        ? Semantics(label: '$label, in progress', child: button)
        : button;
  }
}

/// Text input with the NexaAid look. `password: true` adds the
/// show/hide eye button (adviser item 2).
class AppTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String label;
  final String? hint;
  final String? helper;
  final IconData? icon;
  final bool password;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final int maxLines;

  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.icon,
    this.password = false,
    this.enabled = true,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.validator,
    this.onChanged,
    this.onSubmitted,
    this.autofillHints,
    this.maxLength,
    this.maxLines = 1,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return TextFormField(
      controller: w.controller,
      enabled: w.enabled,
      obscureText: w.password && _hidden,
      enableSuggestions: !w.password,
      autocorrect: !w.password,
      keyboardType: w.keyboardType,
      textInputAction: w.textInputAction,
      textCapitalization: w.textCapitalization,
      inputFormatters: w.inputFormatters,
      validator: w.validator,
      onChanged: w.onChanged,
      onFieldSubmitted: w.onSubmitted,
      autofillHints: w.autofillHints,
      maxLength: w.maxLength,
      maxLines: w.password ? 1 : w.maxLines,
      decoration: InputDecoration(
        labelText: w.label,
        hintText: w.hint,
        helperText: w.helper,
        prefixIcon: w.icon == null ? null : Icon(w.icon),
        suffixIcon: w.password
            ? IconButton(
                tooltip: _hidden ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _hidden = !_hidden),
                icon: Icon(
                  _hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              )
            : null,
      ),
    );
  }
}

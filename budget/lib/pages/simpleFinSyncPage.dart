import 'package:budget/database/tables.dart';
import 'package:budget/simplefin/simplefin_client.dart';
import 'package:budget/simplefin/simplefin_service.dart';
import 'package:budget/simplefin/simplefin_storage.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/colors.dart';
import 'package:budget/struct/settings.dart';
import 'package:flutter/material.dart';
import 'package:budget/widgets/watchAllWallets.dart';
import 'package:provider/provider.dart';

class SimpleFinSyncPage extends StatefulWidget {
  const SimpleFinSyncPage({super.key});

  @override
  State<SimpleFinSyncPage> createState() => _SimpleFinSyncPageState();
}

class _SimpleFinSyncPageState extends State<SimpleFinSyncPage> {
  bool _isConnected = false;
  bool _loading = true;
  bool _loadingAccounts = false;
  DateTime? _lastSync;
  List<SimplefinAccount> _accounts = [];
  Map<String, String> _mappings = {};
  String? _defaultCategoryPk;
  List<TransactionCategory> _categories = [];
  final _tokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final accessUrl = await SimplefinStorage.getAccessUrl();
    final mappings = SimplefinStorage.getAccountMappings();
    final lastSync = SimplefinStorage.getLastSyncTime();
    final defaultCategory = SimplefinStorage.getDefaultCategoryPk();
    final categories = await database.getAllCategories();

    setState(() {
      _isConnected = accessUrl != null;
      _mappings = mappings;
      _lastSync = lastSync;
      _defaultCategoryPk = defaultCategory;
      _categories =
          categories.where((c) => c.mainCategoryPk == null).toList();
      _loading = false;
    });

    if (accessUrl != null && _accounts.isEmpty) {
      _refreshAccounts();
    }
  }

  Future<void> _refreshAccounts() async {
    setState(() => _loadingAccounts = true);
    try {
      final accounts = await SimplefinService.fetchAccountsForMapping();
      if (mounted) setState(() => _accounts = accounts);
    } catch (e) {
      if (mounted) {
        openSnackbar(SnackbarMessage(
          title: 'Failed to load accounts',
          description: e.toString(),
          icon: appStateSettings["outlinedIcons"]
              ? Icons.warning_outlined
              : Icons.warning_rounded,
        ));
      }
    } finally {
      if (mounted) setState(() => _loadingAccounts = false);
    }
  }

  Future<void> _connect() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      openSnackbar(SnackbarMessage(
        title: 'Enter a Setup Token',
        icon: Icons.info_outline,
      ));
      return;
    }
    await openLoadingPopupTryCatch(() async {
      await SimplefinService.exchangeAndSaveToken(token);
    }, onSuccess: (_) async {
      _tokenController.clear();
      await _load();
      openSnackbar(SnackbarMessage(
        title: 'Connected to SimpleFIN',
        icon: Icons.check_circle_outline,
      ));
    });
  }

  Future<void> _disconnect() async {
    final confirmed = await openPopup(
      context,
      title: 'Disconnect SimpleFIN?',
      description:
          'Your existing transactions will not be deleted, but syncing will stop.',
      icon: appStateSettings["outlinedIcons"]
          ? Icons.link_off_outlined
          : Icons.link_off_rounded,
      onSubmit: () => Navigator.of(context).pop(true),
      onCancel: () => Navigator.of(context).pop(false),
      onSubmitLabel: 'Disconnect',
      onCancelLabel: 'Cancel',
    );
    if (confirmed != true) return;

    await SimplefinStorage.clearAccessUrl();
    await SimplefinStorage.saveAccountMappings({});
    if (mounted) {
      setState(() {
        _isConnected = false;
        _accounts = [];
        _mappings = {};
      });
    }
  }

  Future<void> _clearData() async {
    final confirmed = await openPopup(
      context,
      title: 'Clear Imported Data?',
      description:
          'This will delete all SimpleFIN transactions from Cashew and reset the sync timer. Your accounts/wallets and any manually added transactions will not be affected.',
      icon: appStateSettings["outlinedIcons"]
          ? Icons.delete_sweep_outlined
          : Icons.delete_sweep_rounded,
      onSubmit: () => Navigator.of(context).pop(true),
      onCancel: () => Navigator.of(context).pop(false),
      onSubmitLabel: 'Clear',
      onCancelLabel: 'Cancel',
    );
    if (confirmed != true) return;

    await openLoadingPopupTryCatch(() async {
      return await SimplefinService.clearSyncData();
    }, onSuccess: (result) {
      setState(() => _lastSync = null);
      openSnackbar(SnackbarMessage(
        title: 'Cleared',
        description: '$result transactions deleted',
        icon: Icons.delete_sweep_rounded,
      ));
    });
  }

  Future<void> _syncNow({bool fullSync = false}) async {
    await openLoadingPopupTryCatch(() async {
      return await SimplefinService.sync(fullSync: fullSync);
    }, onSuccess: (result) {
      if (result is SimplefinSyncResult) {
        setState(() => _lastSync = SimplefinStorage.getLastSyncTime());
        openSnackbar(SnackbarMessage(
          title: 'Sync complete',
          description:
              '${result.imported} imported, ${result.skipped} skipped'
              '${result.errors.isNotEmpty ? ', ${result.errors.length} errors' : ''}',
          icon: Icons.sync,
        ));
      }
    });
  }

  void _setMapping(String simplefinAccountId, String? walletPk) {
    final updated = Map<String, String>.from(_mappings);
    if (walletPk == null) {
      updated.remove(simplefinAccountId);
    } else {
      updated[simplefinAccountId] = walletPk;
    }
    SimplefinStorage.saveAccountMappings(updated);
    setState(() => _mappings = updated);
  }

  @override
  Widget build(BuildContext context) {
    final wallets = Provider.of<AllWallets>(context).list;

    return PageFramework(
      dragDownToDismiss: true,
      title: 'SimpleFIN Sync',
      horizontalPaddingConstrained: true,
      listWidgets: [
        if (_loading)
          const Padding(
            padding: EdgeInsetsDirectional.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          // ── Connection section ─────────────────────────────────────────────
          SettingsHeader(title: 'Connection'),

          if (!_isConnected) ...[
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
              child: TextFont(
                text:
                    'Paste your SimpleFIN Setup Token below. You can get one at simplefin.org.',
                fontSize: 13,
                maxLines: 5,
                textColor: getColor(context, 'textLight'),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
              child: TextField(
                controller: _tokenController,
                decoration: InputDecoration(
                  labelText: 'Setup Token',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                maxLines: 3,
                style: TextStyle(fontFamily: 'Inconsolata', fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
            ),
            const SizedBox(height: 16),
          ] else ...[
            SettingsContainer(
              title: 'Connected',
              description: _lastSync != null
                  ? 'Last sync: ${_formatDateTime(_lastSync!)}'
                  : 'Never synced',
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.check_circle_outlined
                  : Icons.check_circle_rounded,
            ),
            SettingsContainer(
              title: 'Sync Now',
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.sync_outlined
                  : Icons.sync_rounded,
              onTap: _loadingAccounts ? null : _syncNow,
            ),
            SettingsContainer(
              title: 'Sync Last 45 Days',
              description: 'Re-import all transactions from the last 45 days',
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.history_outlined
                  : Icons.history_rounded,
              onTap: _loadingAccounts ? null : () => _syncNow(fullSync: true),
            ),
            SettingsContainer(
              title: 'Clear Imported Data',
              description: 'Delete all SimpleFIN transactions from Cashew and reset sync timer',
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.delete_sweep_outlined
                  : Icons.delete_sweep_rounded,
              onTap: _clearData,
            ),
            SettingsContainer(
              title: 'Disconnect',
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.link_off_outlined
                  : Icons.link_off_rounded,
              onTap: _disconnect,
            ),

            // ── Default category ──────────────────────────────────────────────
            SettingsHeader(title: 'Default Category'),
            Padding(
              padding:
                  const EdgeInsetsDirectional.symmetric(horizontal: 16),
              child: TextFont(
                text:
                    'Imported transactions are assigned this category. Recategorize manually after syncing.',
                fontSize: 13,
                maxLines: 5,
                textColor: getColor(context, 'textLight'),
              ),
            ),
            const SizedBox(height: 8),
            if (_categories.isNotEmpty)
              Padding(
                padding:
                    const EdgeInsetsDirectional.symmetric(horizontal: 16),
                child: _CategoryDropdown(
                  categories: _categories,
                  selectedPk: _defaultCategoryPk ?? _categories.first.categoryPk,
                  onChanged: (pk) {
                    SimplefinStorage.saveDefaultCategoryPk(pk);
                    setState(() => _defaultCategoryPk = pk);
                  },
                ),
              ),
            const SizedBox(height: 8),

            // ── Account mapping ───────────────────────────────────────────────
            SettingsHeader(title: 'Account Mapping'),
            Padding(
              padding:
                  const EdgeInsetsDirectional.symmetric(horizontal: 16),
              child: TextFont(
                text:
                    'Map each SimpleFIN account to an existing Cashew account, or leave as "Auto-create account" to have Cashew create one automatically on first sync.',
                fontSize: 13,
                maxLines: 5,
                textColor: getColor(context, 'textLight'),
              ),
            ),
            const SizedBox(height: 8),
            if (_loadingAccounts)
              const Padding(
                padding: EdgeInsetsDirectional.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_accounts.isEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
                child: TextFont(
                  text: 'No accounts found. Tap Sync Now to fetch.',
                  fontSize: 13,
                  textColor: getColor(context, 'textLight'),
                ),
              )
            else
              for (final account in _accounts)
                _AccountMappingRow(
                  account: account,
                  wallets: wallets,
                  selectedWalletPk: _mappings[account.id],
                  onChanged: (walletPk) => _setMapping(account.id, walletPk),
                ),
            const SizedBox(height: 16),
          ],
        ],
      ],
    );
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${_pad(local.month)}-${_pad(local.day)} '
        '${_pad(local.hour)}:${_pad(local.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

class _CategoryDropdown extends StatelessWidget {
  const _CategoryDropdown({
    required this.categories,
    required this.selectedPk,
    required this.onChanged,
  });

  final List<TransactionCategory> categories;
  final String selectedPk;
  final void Function(String pk) onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: categories.any((c) => c.categoryPk == selectedPk)
          ? selectedPk
          : categories.first.categoryPk,
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding:
            const EdgeInsetsDirectional.symmetric(horizontal: 12, vertical: 8),
      ),
      items: categories
          .map((c) => DropdownMenuItem(
                value: c.categoryPk,
                child: TextFont(text: c.name, fontSize: 14),
              ))
          .toList(),
      onChanged: (pk) {
        if (pk != null) onChanged(pk);
      },
    );
  }
}

class _AccountMappingRow extends StatelessWidget {
  const _AccountMappingRow({
    required this.account,
    required this.wallets,
    required this.selectedWalletPk,
    required this.onChanged,
  });

  final SimplefinAccount account;
  final List<TransactionWallet> wallets;
  final String? selectedWalletPk;
  final void Function(String? walletPk) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFont(
                  text: account.name,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                TextFont(
                  text: account.orgName,
                  fontSize: 12,
                  textColor: getColor(context, 'textLight'),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: DropdownButtonFormField<String?>(
              value: selectedWalletPk == 'auto'
                  ? 'auto'
                  : wallets.any((w) => w.walletPk == selectedWalletPk)
                      ? selectedWalletPk
                      : null,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 12, vertical: 8),
              ),
              hint: TextFont(
                text: 'Skip',
                fontSize: 13,
                textColor: getColor(context, 'textLight'),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Skip'),
                ),
                const DropdownMenuItem<String?>(
                  value: 'auto',
                  child: Text('Auto-create account'),
                ),
                ...wallets.map((w) => DropdownMenuItem<String?>(
                      value: w.walletPk,
                      child: TextFont(text: w.name, fontSize: 13),
                    )),
              ],
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

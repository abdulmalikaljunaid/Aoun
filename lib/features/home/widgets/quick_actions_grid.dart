import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quran_connect/features/bookmarks/screens/bookmarks_screen.dart';
import 'package:quran_connect/features/statistics/screens/statistics_screen.dart';
import 'package:quran_connect/features/achievements/screens/achievements_screen.dart';
import 'package:quran_connect/features/settings/screens/settings_screen.dart';
import 'package:quran_connect/features/social/screens/social_screen.dart';
import 'package:quran_connect/core/design_system/tokens/app_colors.dart';
import 'package:go_router/go_router.dart';

class QuickActionsGrid extends ConsumerWidget {
  final Function(int) onActionSelected;
  final VoidCallback? onNavigateToMushaf;

  const QuickActionsGrid({
    super.key,
    required this.onActionSelected,
    this.onNavigateToMushaf,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Title
          Row(
            children: [
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'الاختصارات',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Row 1
          Row(
            children: [
              Expanded(
                child: _QuickActionCard(
                  title: 'العلامات',
                  icon: Icons.bookmark_rounded,
                  gradientColors: const [
                    AppColors.secondary,
                    AppColors.secondaryDeep,
                  ],
                  isDark: isDark,
                  theme: theme,
                  onTap: () async {
                    final openedInMushaf = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BookmarksScreen(),
                      ),
                    );
                    if (openedInMushaf == true) {
                      onNavigateToMushaf?.call();
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _QuickActionCard(
                  title: 'إحصائياتي',
                  icon: Icons.bar_chart_rounded,
                  gradientColors: const [
                    AppColors.primary,
                    AppColors.primaryDeep,
                  ],
                  isDark: isDark,
                  theme: theme,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const StatisticsScreen(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _QuickActionCard(
                  title: 'إنجازاتي',
                  icon: Icons.emoji_events_rounded,
                  gradientColors: const [
                    AppColors.accent,
                    AppColors.accentDeep,
                  ],
                  isDark: isDark,
                  theme: theme,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AchievementsScreen(),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Row 2
          Row(
            children: [
              Expanded(
                child: _QuickActionCard(
                  title: 'مجتمعي',
                  icon: Icons.group_rounded,
                  gradientColors: const [
                    AppColors.primaryDeep,
                    AppColors.emeraldDarkest,
                  ],
                  isDark: isDark,
                  theme: theme,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SocialScreen(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _QuickActionCard(
                  title: 'الإعدادات',
                  icon: Icons.tune_rounded,
                  gradientColors: const [AppColors.sage, AppColors.sageDeep],
                  isDark: isDark,
                  theme: theme,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SettingsScreen(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _QuickActionCard(
                  title: 'القبلة',
                  icon: Icons.explore_rounded,
                  gradientColors: const [
                    AppColors.accent,
                    AppColors.accentDeep,
                  ],
                  isDark: isDark,
                  theme: theme,
                  onTap: () {
                    context.push('/qibla');
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickActionCard extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Color> gradientColors;
  final bool isDark;
  final ThemeData theme;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.title,
    this.subtitle,
    required this.icon,
    required this.gradientColors,
    required this.isDark,
    required this.theme,
    required this.onTap,
  });

  @override
  State<_QuickActionCard> createState() => _QuickActionCardState();
}

class _QuickActionCardState extends State<_QuickActionCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.gradientColors[0];

    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: _ScaleTransitionBuilder(
        animation: _scaleAnimation,
        builder: (context, child) => Transform.scale(
          scale: _scaleAnimation.value,
          child: child,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            color: widget.isDark
                ? baseColor.withValues(alpha: 0.12)
                : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: widget.isDark
                  ? baseColor.withValues(alpha: 0.15)
                  : baseColor.withValues(alpha: 0.08),
            ),
            boxShadow: widget.isDark
                ? []
                : [
                    BoxShadow(
                      color: baseColor.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: widget.gradientColors,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: baseColor.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(widget.icon, color: Colors.white, size: 22),
              ),
              const SizedBox(height: 10),
              Text(
                widget.title,
                style: widget.theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5,
                  color: widget.theme.colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  widget.subtitle!,
                  style: widget.theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9.5,
                    height: 1.25,
                    color: widget.theme.colorScheme.onSurface
                        .withValues(alpha: 0.6),
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Scale transition builder for press animation
class _ScaleTransitionBuilder extends AnimatedWidget {
  final Widget Function(BuildContext, Widget?) builder;
  final Widget? child;

  const _ScaleTransitionBuilder({
    required Animation<double> animation,
    required this.builder,
    this.child,
  }) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    return builder(context, child);
  }
}

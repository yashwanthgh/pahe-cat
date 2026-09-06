import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../models/anime.dart';
import '../services/cf_session.dart';
import '../theme.dart';

class AnimeCard extends StatelessWidget {
  final Anime anime;
  final VoidCallback onTap;

  const AnimeCard({super.key, required this.anime, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: PaheColors.card,
          border: Border.all(color: PaheColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 2:3 is the poster's real shape; the grid reserves height to match.
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: anime.poster,
                    // animepahe's image host enforces hotlink protection, so a
                    // bare request returns no image.
                    httpHeaders: CfSession().dioHeaders,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Shimmer.fromColors(
                      baseColor: PaheColors.card,
                      highlightColor: PaheColors.cardHover,
                      child: Container(color: PaheColors.card),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: PaheColors.card,
                      child: const Icon(Icons.broken_image_rounded,
                          color: PaheColors.textMuted),
                    ),
                  ),
                  // type badge
                  Positioned(
                    top: 6, left: 6,
                    child: _Badge(
                      text: anime.type,
                      color: anime.type == 'Movie'
                          ? PaheColors.accent2
                          : PaheColors.accent,
                    ),
                  ),
                  // score badge
                  if (anime.score > 0)
                    Positioned(
                      top: 6, right: 6,
                      child: _Badge(
                        text: anime.score.toStringAsFixed(1),
                        color: PaheColors.amber,
                        icon: Icons.star_rounded,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(7, 6, 7, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      anime.title,
                      style: const TextStyle(
                        color: PaheColors.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    if (anime.subtitle.isNotEmpty)
                      Text(
                        anime.subtitle,
                        style: const TextStyle(
                          color: PaheColors.textMuted,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;

  const _Badge({required this.text, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 9, color: Colors.white),
            const SizedBox(width: 2),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

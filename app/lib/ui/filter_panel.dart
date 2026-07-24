import 'package:flutter/material.dart';

class FilterPanel extends StatelessWidget {
  final String title;
  final List<String> values;
  final String? selected;
  final ValueChanged<String?> onSelect;
  const FilterPanel({
    super.key,
    required this.title,
    required this.values,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('All (${values.length})'),
                selected: selected == null,
                onTap: () => onSelect(null),
              ),
              for (final v in values)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(v, maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: v == selected,
                  onTap: () => onSelect(v == selected ? null : v),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

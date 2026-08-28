import 'package:intl/intl.dart';

extension DateTimeExtensions on DateTime {
  String get toDateString => DateFormat('yyyy-MM-dd').format(this);
  String get toDateTimeString => DateFormat('yyyy-MM-dd HH:mm').format(this);
  String get toDisplayDate => DateFormat('dd/MM/yyyy').format(this);
  String get toDisplayDateTime => DateFormat('dd/MM/yyyy hh:mm a').format(this);
  String get toTimeString => DateFormat('hh:mm a').format(this);
  
  String get timeAgo {
    final now = DateTime.now();
    final difference = now.difference(this);
    
    if (difference.inDays > 365) {
      return '${(difference.inDays / 365).floor()} years ago';
    } else if (difference.inDays > 30) {
      return '${(difference.inDays / 30).floor()} months ago';
    } else if (difference.inDays > 0) {
      return '${difference.inDays} days ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} hours ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} minutes ago';
    } else {
      return 'Just now';
    }
  }

  bool get isToday {
    final now = DateTime.now();
    return year == now.year && month == now.month && day == now.day;
  }

  bool get isYesterday {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return year == yesterday.year && month == yesterday.month && day == yesterday.day;
  }
}

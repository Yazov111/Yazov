select setval(pg_get_serial_sequence('public.submissions','id'), (select max(id) from public.submissions));
select setval(pg_get_serial_sequence('public.comments','id'), (select max(id) from public.comments));
select setval(pg_get_serial_sequence('public.piece_images','id'), (select count(*) from public.piece_images));
select setval(pg_get_serial_sequence('public.notifications','id'), 1, false);

-- 完成。验证：select count(*) from public.submissions; 应为 3

-- 全部完成后：select count(*) from public.submissions; 应为 3

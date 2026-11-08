-- The eight worked checks for duplicate classification (reference section 6.1, step 3). Every one runs in both orders.
-- Day: 2 Nov 2026, Madrid time (UTC+1).
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- verdict of the pair (a, b) as "rule" or "rule:preselect"
create function pg_temp.pair(a_src text, a_ticket text, a_at text, a_total int, b_src text, b_ticket text, b_at text, b_total int)
returns text language sql as $$
  select rule || coalesce(':' || preselect, '') || case when evidence is not null then ' (evidence)' else '' end
  from public._dup_pair(a_src, a_ticket, a_at::timestamptz, a_total, a_at::timestamptz,
                        b_src, b_ticket, b_at::timestamptz, b_total, b_at::timestamptz)
$$;

-- 1. crumpled ticket photographed twice: same printed minute and total
select is(pg_temp.pair('printed', null, '2026-11-02 18:12+01', 4560, 'printed', null, '2026-11-02 18:12+01', 4560), 'C2', '1 photographed twice (a,b)');

-- 2. same ticket from app and e-ticket
select is(pg_temp.pair('printed', '2304011123456', '2026-11-02 18:12+01', 4560, 'printed', '2304011123456', '2026-11-02 18:12+01', 4560), 'C1', '2a same normalised number');
select is(pg_temp.pair('printed', '2304011123456', '2026-11-02 18:12+01', 4560, 'printed', null, '2026-11-02 18:12+01', 4560), 'C2', '2b number omitted: same minute and total');
select is(pg_temp.pair('printed', '2304011123456', '2026-11-02 18:12+01', 4560, 'printed', null, '2026-11-02 18:12+01', 4560),
          pg_temp.pair('printed', null, '2026-11-02 18:12+01', 4560, 'printed', '2304011123456', '2026-11-02 18:12+01', 4560), '2b same in the other order');
select is(pg_temp.pair('printed', '2304011123456', '2026-11-02 18:12+01', 4560, 'entered', null, '2026-11-02 18:30+01', 4560), 'C3:same', '2c number and time omitted (a,b)');
select is(pg_temp.pair('entered', null, '2026-11-02 18:30+01', 4560, 'printed', '2304011123456', '2026-11-02 18:12+01', 4560), 'C3:same', '2c (b,a)');

-- 3. typed after its receipt, and the opposite order
select is(pg_temp.pair('printed', null, '2026-11-02 18:12+01', 4560, 'entered', null, '2026-11-02 21:00+01', 4600), 'C5', '3 receipt then typed 21:00');
select is(pg_temp.pair('entered', null, '2026-11-02 21:00+01', 4600, 'printed', null, '2026-11-02 18:12+01', 4560), 'C5', '3 typed 21:00 then receipt');
select is(pg_temp.pair('entered', null, '2026-11-02 18:20+01', 4600, 'printed', null, '2026-11-02 18:12+01', 4560), 'C5', '3 typed 18:20 (a,b)');
select is(pg_temp.pair('printed', null, '2026-11-02 18:12+01', 4560, 'entered', null, '2026-11-02 18:20+01', 4600), 'C5', '3 typed 18:20 (b,a)');

-- 4. misread ticket number, same total: C3 with "same ticket" preselected
select is(pg_temp.pair('printed', '2304011123456', '2026-11-02 18:12+01', 4560, 'entered', '2304011128456', '2026-11-02 19:00+01', 4560), 'C3:same', '4 (a,b)');
select is(pg_temp.pair('entered', '2304011128456', '2026-11-02 19:00+01', 4560, 'printed', '2304011123456', '2026-11-02 18:12+01', 4560), 'C3:same', '4 (b,a)');
-- ... and with different totals the near-match numbers still ask (C4)
select is(pg_temp.pair('printed', '2304011123456', '2026-11-02 18:12+01', 4560, 'entered', '2304011128456', '2026-11-02 19:00+01', 4000), 'C4', '4 different totals: C4 (a,b)');
select is(pg_temp.pair('entered', '2304011128456', '2026-11-02 19:00+01', 4000, 'printed', '2304011123456', '2026-11-02 18:12+01', 4560), 'C4', '4 different totals: C4 (b,a)');

-- 5. two real EUR 45.60 runs: typed 10:15, ticket 19:40 -> question with evidence, nothing preselected
select is(pg_temp.pair('entered', null, '2026-11-02 10:15+01', 4560, 'printed', null, '2026-11-02 19:40+01', 4560), 'C3 (evidence)', '5 (a,b)');
select is(pg_temp.pair('printed', null, '2026-11-02 19:40+01', 4560, 'entered', null, '2026-11-02 10:15+01', 4560), 'C3 (evidence)', '5 (b,a)');

-- 6. morning total typed at 23:00 after the 19:40 ticket: "same" preselected
select is(pg_temp.pair('entered', null, '2026-11-02 23:00+01', 4560, 'printed', null, '2026-11-02 19:40+01', 4560), 'C3:same', '6 (a,b)');
select is(pg_temp.pair('printed', null, '2026-11-02 19:40+01', 4560, 'entered', null, '2026-11-02 23:00+01', 4560), 'C3:same', '6 (b,a)');

-- 7. different totals, ticket printed long after typing: separate trips
select is(pg_temp.pair('entered', null, '2026-11-02 10:15+01', 3000, 'printed', null, '2026-11-02 19:40+01', 4560), 'C6', '7 (a,b)');
select is(pg_temp.pair('printed', null, '2026-11-02 19:40+01', 4560, 'entered', null, '2026-11-02 10:15+01', 3000), 'C6', '7 (b,a)');

-- 8. misread minute: C6 as read, C5 once corrected
select is(pg_temp.pair('entered', null, '2026-11-02 18:30+01', 4600, 'printed', null, '2026-11-02 19:12+01', 4560), 'C6', '8 misread 19:12 (a,b)');
select is(pg_temp.pair('printed', null, '2026-11-02 19:12+01', 4560, 'entered', null, '2026-11-02 18:30+01', 4600), 'C6', '8 misread 19:12 (b,a)');
select is(pg_temp.pair('entered', null, '2026-11-02 18:30+01', 4600, 'printed', null, '2026-11-02 18:12+01', 4560), 'C5', '8 corrected 18:12 (a,b)');
select is(pg_temp.pair('printed', null, '2026-11-02 18:12+01', 4560, 'entered', null, '2026-11-02 18:30+01', 4600), 'C5', '8 corrected 18:12 (b,a)');

-- Two receipts, different totals, tickets 5 apart, different minutes: separate trips (C6)
select is(pg_temp.pair('printed', 'AAAAAAAAAA', '2026-11-02 18:12+01', 4560, 'printed', 'AAAAABBBBB', '2026-11-02 19:40+01', 3000), 'C6', 'two different receipts');

select * from finish();
rollback;

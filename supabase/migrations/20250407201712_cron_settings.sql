-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                               Crons                                ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- ╭─────────────────────◉ CONTEXTO: Sistema ◉─────────────────────────╮
-- ┃                         Jobs do sistema                            ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criação de jobs de vacuum e analyze
SELECT cron.schedule(
  'vacuum_analyze_diario',
  '0 3 * * *',  -- Todos os dias às 03:00 (GMT)
  'VACUUM ANALYZE'
);

-- Cron para limpeza da tabela de histórico de execução
SELECT cron.schedule(
  'cleanup-cron-history',
  '30 3 * * *',  -- todos os dias às 3:30 da manhã (GMT)
  $$
  DELETE FROM cron.job_run_details
  WHERE end_time < now() - interval '7 days'
  $$
);

SELECT cron.schedule(
  'cleanup-logs-history',
  '0 4 * * *',  -- todos os dias às 4:00 da manhã (GMT)
  $$
  DELETE FROM private.process_logs
  WHERE created_at < now() - interval '30 days'
  $$
);


-- ╭─────────────────────◉ CONTEXTO: Usuários ◉────────────────────────╮
-- ┃                        Gestão de usuários                          ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Cria um job agendado para deletar usuários inativos diariamente às 01:00 BRT (04:00 UTC)
SELECT cron.schedule(
  'delete_inactive_auth_users',
  '30 4 * * *', -- todos os dias às 4:30 da manhã (GMT)
  'SELECT private.fn_delete_inactive_auth_users();'  
);


-- ╭─────────────────────◉ CONTEXTO: Automações ◉──────────────────────╮
-- ┃                  Jobs de automações e followups                    ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Cron para identificar e enfileirar follow-ups agendados a cada minuto
-- (erros são tratados apenas via logs no banco; notify-ops é exclusivo da Edge send-followup)
SELECT cron.schedule(
  'execute-scheduled-followups',
  '* * * * *',  -- Todo início de hora (UTC)
  'SELECT * FROM private.fn_execute_scheduled_followups_with_alert();'
);

-- Cron para processar a fila de follow-ups a cada 5 minutos
SELECT cron.schedule(
  'process-followup-queue',
  '*/5 * * * *',  -- A cada 5 minutos
  'SELECT * FROM private.fn_process_followup_queue_with_alert(50);'
);

-- Cron para limpar a fila de follow-ups diariamente às 02:00 UTC
SELECT cron.schedule(
  'cleanup-followup-queue',
  '0 5 * * *',  -- todos os dias às 5:00 da manhã (GMT)
  'SELECT * FROM private.fn_cleanup_followup_queue_with_alert();'
);

-- Alerta OPS: cartas de confirmação não enviadas após importação do pedido
-- Offset :10/:40 UTC para rodar após o ciclo principal de follow-up
SELECT cron.schedule(
  'check-confirmation-letter-failures',
  '10,40 * * * *',
  'SELECT private.fn_trigger_confirmation_letter_alert();'
);
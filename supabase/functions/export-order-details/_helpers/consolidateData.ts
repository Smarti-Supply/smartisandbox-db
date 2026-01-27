type RecordStr = Record<string, unknown>;

function formatArrayAsString(array: unknown[], separator = "; "): string {
  if (!array || array.length === 0) return "";
  const formatted = array
    .filter((item) => item != null && String(item).trim() !== "")
    .map((item) => String(item));
  return formatted.length ? formatted.join(separator) : "";
}

export function consolidateData(
  orderId: number,
  order: RecordStr,
  orderItems: RecordStr[],
  observations: RecordStr[],
  followupTracking: RecordStr[],
  orderItemInvoices: RecordStr[] = []
): RecordStr[] {
  const orderItemsById: Record<number, RecordStr> = {};

  for (const item of orderItems) {
    const numeroItem = item.numero_item as number | undefined;
    const dbId = (item.id_item ?? item.id) as number | undefined;
    const orderItemId = item.order_item_id as number | undefined;

    if (numeroItem != null) {
      orderItemsById[numeroItem] = item;
    } else if (dbId != null) {
      orderItemsById[dbId] = item;
    } else if (orderItemId != null) {
      orderItemsById[orderItemId] = item;
    }
  }

  const observationsByItem: Record<number, RecordStr[]> = {};
  const observationsOrderLevel: RecordStr[] = [];

  for (const obs of observations) {
    const itemId = obs.numero_item as number | undefined;
    if (itemId != null) {
      if (!observationsByItem[itemId]) observationsByItem[itemId] = [];
      observationsByItem[itemId].push(obs);
    } else {
      observationsOrderLevel.push(obs);
    }
  }

  const followupsByItem: Record<number, RecordStr[]> = {};
  const followupsOrderLevel: RecordStr[] = [];

  for (const followup of followupTracking) {
    const itemId = followup.numero_item as number | undefined;
    if (itemId != null) {
      if (itemId in orderItemsById) {
        if (!followupsByItem[itemId]) followupsByItem[itemId] = [];
        followupsByItem[itemId].push(followup);
      } else {
        followupsOrderLevel.push(followup);
      }
    } else {
      followupsOrderLevel.push(followup);
    }
  }

  const invoicesByItem: Record<number, RecordStr[]> = {};
  for (const inv of orderItemInvoices) {
    const itemId = inv.numero_item as number | undefined;
    if (itemId != null) {
      if (!invoicesByItem[itemId]) invoicesByItem[itemId] = [];
      invoicesByItem[itemId].push(inv);
    }
  }

  const allItemIds = new Set(Object.keys(orderItemsById).map(Number));
  if (allItemIds.size === 0) return [];

  const consolidatedRows: RecordStr[] = [];

  for (const itemId of [...allItemIds].sort((a, b) => a - b)) {
    const orderItem = orderItemsById[itemId] ?? {};
    const itemObservations = [
      ...(observationsByItem[itemId] ?? []),
      ...observationsOrderLevel,
    ];
    const itemFollowups = [
      ...(followupsByItem[itemId] ?? []),
      ...followupsOrderLevel,
    ];
    const itemInvoices = invoicesByItem[itemId] ?? [];

    const row: RecordStr = {};

    for (const [k, v] of Object.entries(order)) {
      if (v != null) row[k] = v;
    }
    row.id_pedido = orderId;

    for (const [k, v] of Object.entries(orderItem)) {
      if (v != null) row[k] = v;
    }
    if (row.numero_item == null) row.numero_item = itemId;

    const userObservations = itemObservations
      .map((o) => o.observacao_do_usuario)
      .filter((v) => v != null && v !== "");
    const supplierObservations = itemObservations
      .map((o) => o.observacao_do_fornecedor)
      .filter((v) => v != null && v !== "");
    const deliveryDates = itemObservations
      .map((o) => o.data_da_entrega)
      .filter((v) => v != null);
    const ruleNames = itemFollowups
      .map((f) => f.regras_de_followup)
      .filter((v) => v != null && v !== "");

    const invoiceNfes = itemInvoices
      .map((i) => i.numero_nfe)
      .filter((v) => v != null);
    const invoiceDatas = itemInvoices
      .map((i) => i.data_nfe)
      .filter((v) => v != null);
    const invoiceQuantidades = itemInvoices
      .map((i) => i.quantidade_faturada)
      .filter((v) => v != null);
    const invoiceCriadoEm = itemInvoices
      .map((i) => i.criado_em)
      .filter((v) => v != null);

    row["observacao do usuario"] = formatArrayAsString(userObservations, "; ");
    row["observacao do fornecedor"] = formatArrayAsString(
      supplierObservations,
      "; "
    );
    row["regras de followup"] = formatArrayAsString(ruleNames, "; ");
    row.numero_nfe = formatArrayAsString(invoiceNfes, "; ");
    row.data_nfe = formatArrayAsString(invoiceDatas, "; ");
    row.quantidade_faturada = formatArrayAsString(invoiceQuantidades, "; ");
    row.quantidade_faturada_criado_em = formatArrayAsString(
      invoiceCriadoEm,
      "; "
    );

    if (deliveryDates.length > 0) {
      row.data_da_entrega = deliveryDates[0];
    }

    consolidatedRows.push(row);
  }

  return consolidatedRows;
}

import { jsPDF } from "npm:jspdf@2.5.2";
// No Deno/ESM o pacote pode expor a função em .default
import autoTableModule from "npm:jspdf-autotable@3.8.2";
type AutoTableFn = (doc: unknown, opts: unknown) => void;
const autoTable: AutoTableFn =
  typeof (autoTableModule as { default?: unknown }).default === "function"
    ? (autoTableModule as { default: AutoTableFn }).default
    : (autoTableModule as AutoTableFn);

type RecordStr = Record<string, unknown>;

function formatDate(dateStr: string | null | undefined): string {
  if (!dateStr) return "";
  try {
    const s = dateStr.replace("Z", "+00:00");
    const dt = new Date(s);
    if (isNaN(dt.getTime())) return dateStr;
    const d = dt.getDate().toString().padStart(2, "0");
    const m = (dt.getMonth() + 1).toString().padStart(2, "0");
    const y = dt.getFullYear();
    return `${d}/${m}/${y}`;
  } catch {
    return dateStr;
  }
}

function formatDateTime(dtStr: string | null | undefined): string {
  if (!dtStr) return "";
  try {
    const s = dtStr.replace("Z", "+00:00");
    const dt = new Date(s);
    if (isNaN(dt.getTime())) {
      const d = new Date(dtStr);
      return d.toLocaleDateString("pt-BR");
    }
    const d = dt.getDate().toString().padStart(2, "0");
    const m = (dt.getMonth() + 1).toString().padStart(2, "0");
    const y = dt.getFullYear();
    const h = dt.getHours().toString().padStart(2, "0");
    const min = dt.getMinutes().toString().padStart(2, "0");
    return `${d}/${m}/${y} ${h}:${min}`;
  } catch {
    return dtStr ?? "";
  }
}

function formatUser(
  userNome: string | null | undefined,
  userEmail: string | null | undefined
): string {
  const nome = (userNome ?? "").toString().trim();
  const email = (userEmail ?? "").toString().trim();
  if (nome && email) return `${nome} (${email})`;
  if (nome) return nome;
  if (email) return email;
  return "-";
}

interface TimelineEvent {
  date: string | null;
  description: string;
  user: string;
}

function createTimelineEvents(
  order: RecordStr,
  _orderItems: RecordStr[],
  observations: RecordStr[],
  followupTracking: RecordStr[],
  followupLogs: RecordStr[],
  orderItemInvoices: RecordStr[]
): TimelineEvent[] {
  const events: TimelineEvent[] = [];
  const pedidoCriadoEm =
    (order.pedido_criado_em as string) ?? (order.created_at as string);

  for (const obs of observations) {
    const itemId = obs.numero_item as number | undefined;
    const itemDesc = itemId != null ? `Item ${itemId}` : "Pedido";
    const criadoEm =
      (obs.criado_em as string) ??
      (obs.created_at as string) ??
      (obs.data_criacao as string) ??
      pedidoCriadoEm;
    const observacaoUsuario = obs.observacao_do_usuario;
    const observacaoFornecedor = obs.observacao_do_fornecedor;
    const userFormatted = formatUser(
      obs.usuario_nome as string,
      obs.usuario_email as string
    );
    const dataFormatada = criadoEm ? formatDateTime(criadoEm) : "";
    const suffix = dataFormatada ? ` (${dataFormatada})` : "";

    if (observacaoUsuario) {
      events.push({
        date: criadoEm ?? null,
        description: `Observação Diligenciador (${itemDesc})${suffix}: ${observacaoUsuario}`,
        user: userFormatted,
      });
    }
    if (observacaoFornecedor) {
      events.push({
        date: criadoEm ?? null,
        description: `Observação Fornecedor (${itemDesc})${suffix}: ${observacaoFornecedor}`,
        user: userFormatted,
      });
    }
  }

  for (const followup of followupTracking) {
    const itemId = followup.numero_item as number | undefined;
    const itemDesc = itemId != null ? `Item ${itemId}` : "Pedido";
    const criadoEm = followup.criado_em as string;
    const regra = followup.regras_de_followup as string;
    const userFormatted = formatUser(
      followup.usuario_nome as string,
      followup.usuario_email as string
    );
    if (regra) {
      events.push({
        date: criadoEm ?? null,
        description: `Status do ${itemDesc} alterado para "${regra}"`,
        user: userFormatted,
      });
    }
  }

  for (const log of followupLogs) {
    const sentAt = (log.sent_at ?? log.created_at) as string;
    const isAutomatic = log.is_automatic as boolean;
    const notificationType = (log.notification_type as string) ?? "email";
    const supplierContacts = (log.supplier_contacts as string[]) ?? [];
    const userObservations = (log.user_observations as string) ?? "";
    const sentBy = (log.sent_by as string) ?? "";
    const ruleName = (log.rule_name as string) ?? "";
    const tipoNotificacao =
      notificationType === "email" ? "Email" : notificationType;
    const contatosStr = supplierContacts.length
      ? supplierContacts.join(", ")
      : "N/A";
    const enviadoPor = isAutomatic
      ? "Sistema (automático)"
      : sentBy
        ? `Usuário (${sentBy})`
        : "Usuário";
    const descParts: string[] = [];
    if (ruleName.trim()) {
      descParts.push(`Regra: ${ruleName}`);
      descParts.push("-");
    }
    descParts.push(`Followup enviado via ${tipoNotificacao}`);
    if (contatosStr && contatosStr !== "N/A") descParts.push(`para ${contatosStr}`);
    descParts.push(`(${enviadoPor})`);
    if (userObservations.trim()) {
      const short =
        userObservations.length > 100
          ? userObservations.slice(0, 100) + "..."
          : userObservations;
      descParts.push(`- ${short}`);
    }
    events.push({
      date: sentAt ?? null,
      description: descParts.join(" "),
      user: enviadoPor,
    });
  }

  for (const inv of orderItemInvoices) {
    const itemId = inv.numero_item as number | undefined;
    const itemDesc = itemId != null ? `Item ${itemId}` : "Pedido";
    const criadoEm = inv.criado_em as string;
    const numeroNfe = inv.numero_nfe;
    const quantidade = inv.quantidade_faturada;
    const dataNfe = inv.data_nfe;
    const userFormatted = formatUser(
      inv.usuario_nome as string,
      inv.usuario_email as string
    );
    const descParts = [`${itemDesc} - faturado`];
    if (quantidade) descParts.push(`${quantidade} unidades`);
    if (numeroNfe) descParts.push(`- NF ${numeroNfe}`);
    if (dataNfe) descParts.push(`(Data NF: ${formatDate(dataNfe as string)})`);
    events.push({
      date: criadoEm ?? null,
      description: descParts.join(" "),
      user: userFormatted,
    });
  }

  events.sort((a, b) => {
    const da = a.date ?? "";
    const db = b.date ?? "";
    if (!da && !db) return 0;
    if (!da) return 1;
    if (!db) return -1;
    return new Date(da).getTime() - new Date(db).getTime();
  });

  return events;
}

export function generatePdf(
  order: RecordStr,
  orderItems: RecordStr[],
  observations: RecordStr[],
  followupTracking: RecordStr[],
  followupLogs: RecordStr[],
  orderItemInvoices: RecordStr[]
): Uint8Array {
  const doc = new jsPDF({
    orientation: "portrait",
    unit: "mm",
    format: "a4",
  });
  const pageWidth = doc.internal.pageSize.getWidth();
  const margin = 20;
  let y = 20;

  doc.setFontSize(18);
  doc.setFont("helvetica", "bold");
  doc.text("Relatório do Pedido", pageWidth / 2, y, { align: "center" });
  y += 15;

  const numeroPedido = String(order.numero_pedido ?? "N/A");
  const fornecedor = String(order.fornecedor ?? "N/A");
  const dataRemessa = formatDate(order.pedido_data_da_remessa as string);
  const valorTotal = orderItems.reduce((acc, item) => {
    const v = item.preco_total as number | undefined;
    return acc + (typeof v === "number" ? v : 0);
  }, 0);
  const valorTotalStr = `R$ ${valorTotal.toLocaleString("pt-BR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;

  doc.setFontSize(11);
  doc.setFont("helvetica", "normal");
  doc.text(`Número do Pedido: ${numeroPedido}`, margin, y);
  y += 6;
  doc.text(`Nome do Fornecedor: ${fornecedor}`, margin, y);
  y += 6;
  doc.text(`Data da Remessa: ${dataRemessa}`, margin, y);
  y += 6;
  doc.text(`Valor Total: ${valorTotalStr}`, margin, y);
  y += 15;

  const events = createTimelineEvents(
    order,
    orderItems,
    observations,
    followupTracking,
    followupLogs,
    orderItemInvoices
  );

  const tableData = events.length
    ? events.map((e) => [
        e.date ? formatDateTime(e.date) : "-",
        e.description,
        e.user,
      ])
    : [["-", "Nenhum evento registrado", "-"]];

  autoTable(doc, {
    startY: y,
    head: [["Data", "Descrição", "Usuário"]],
    body: tableData,
    theme: "grid",
    headStyles: { fillColor: [224, 224, 224], textColor: [0, 0, 0] },
    alternateRowStyles: { fillColor: [245, 245, 245] },
    margin: { left: margin, right: margin },
    columnStyles: {
      0: { cellWidth: 35 },
      1: { cellWidth: 100 },
      2: { cellWidth: 45 },
    },
  });

  const pdfBytes = doc.output("arraybuffer") as ArrayBuffer;
  return new Uint8Array(pdfBytes);
}

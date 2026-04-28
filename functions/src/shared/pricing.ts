import { getAppSettings } from "./config";
import {
  enqueuePricingRefresh,
  getPricingCacheEntity,
  upsertPricingCacheEntity,
} from "./storage";
import {
  PricingCacheEntity,
  PricingCacheRecord,
  PricingLookupRequest,
  PricingModel,
  PricingRefreshQueueMessage,
  PricingRefreshReason,
} from "./types";

interface RetailPriceApiResponse {
  Items?: RetailPriceItem[];
  NextPageLink?: string;
}

interface RetailPriceItem {
  type?: string;
  unitOfMeasure?: string;
  reservationTerm?: string;
  armSkuName?: string;
  skuName?: string;
  productName?: string;
  meterName?: string;
  retailPrice?: number;
  currencyCode?: string;
  isPrimaryMeterRegion?: boolean | string | null;
}

interface PriceMatch {
  item: RetailPriceItem;
  matchType: string;
}

interface PricingKeyParts {
  key: string;
  partitionKey: string;
  rowKey: string;
  licenseMode: string;
}

interface GetPricingModelOptions {
  enqueueRefreshOnMiss?: boolean;
}

const RETAIL_PRICES_BASE_URI =
  "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&meterRegion='primary'";

function normalizeLookupRequest(request: PricingLookupRequest): PricingLookupRequest {
  return {
    armRegionName: request.armRegionName.trim(),
    armSkuName: request.armSkuName.trim(),
    osType: request.osType.trim() || "Unknown",
    licenseType: request.licenseType?.trim() || "",
  };
}

function getLicenseMode(osType: string, licenseType?: string): string {
  return hasWindowsLicenseBenefit(osType, licenseType) ? "benefit" : "standard";
}

export function getPricingKeyParts(request: PricingLookupRequest): PricingKeyParts {
  const normalized = normalizeLookupRequest(request);
  const normalizedRegion = normalized.armRegionName.toLowerCase();
  const normalizedSku = normalized.armSkuName.toLowerCase();
  const normalizedOsType = normalized.osType.toLowerCase();
  const licenseMode = getLicenseMode(normalized.osType, normalized.licenseType);
  const partitionKey = `pricing:${normalizedRegion}`;
  const rowKey = `${normalizedSku}|${normalizedOsType}|${licenseMode}`;

  return {
    key: `${partitionKey}|${rowKey}`,
    partitionKey,
    rowKey,
    licenseMode,
  };
}

function projectPricingModel(entity: PricingCacheEntity): PricingModel {
  return {
    CurrencyCode: entity.CurrencyCode,
    PaygHourly: entity.PaygHourly,
    PaygMonthly: entity.PaygMonthly,
    PaygComputeMonthly: entity.PaygComputeMonthly,
    Reservation1YearTotal: entity.Reservation1YearTotal,
    Reservation1YearMonthly: entity.Reservation1YearMonthly,
    Reservation1YearComputeMonthly: entity.Reservation1YearComputeMonthly,
    Reservation3YearTotal: entity.Reservation3YearTotal,
    Reservation3YearMonthly: entity.Reservation3YearMonthly,
    Reservation3YearComputeMonthly: entity.Reservation3YearComputeMonthly,
    IncludeOsLicense: entity.IncludeOsLicense,
    LicenseBenefitApplied: entity.LicenseBenefitApplied,
    OsLicenseHourly: entity.OsLicenseHourly,
    OsLicenseMonthly: entity.OsLicenseMonthly,
    OsLicenseStatus: entity.OsLicenseStatus,
    PricingStatus: entity.PricingStatus,
    PaygMatchType: entity.PaygMatchType,
    Reservation1YearMatchType: entity.Reservation1YearMatchType,
    Reservation3YearMatchType: entity.Reservation3YearMatchType,
    MeterName: entity.MeterName,
    ProductName: entity.ProductName,
  };
}

function buildCacheRecord(
  request: PricingLookupRequest,
  entity: PricingCacheEntity,
  cacheStatus: PricingCacheRecord["cacheStatus"],
): PricingCacheRecord {
  return {
    key: getPricingKeyParts(request).key,
    lookup: normalizeLookupRequest(request),
    model: projectPricingModel(entity),
    cacheStatus,
    fetchedAt: entity.fetchedAt,
    expiresAt: entity.expiresAt,
  };
}

function createFallbackPricingModel(): PricingModel {
  return {
    CurrencyCode: "USD",
    PaygHourly: 0,
    PaygMonthly: 0,
    PaygComputeMonthly: 0,
    Reservation1YearTotal: 0,
    Reservation1YearMonthly: 0,
    Reservation1YearComputeMonthly: 0,
    Reservation3YearTotal: 0,
    Reservation3YearMonthly: 0,
    Reservation3YearComputeMonthly: 0,
    IncludeOsLicense: false,
    LicenseBenefitApplied: false,
    OsLicenseHourly: 0,
    OsLicenseMonthly: 0,
    OsLicenseStatus: "LookupFailed",
    PricingStatus: "Pricing lookup failed",
    PaygMatchType: "",
    Reservation1YearMatchType: "",
    Reservation3YearMatchType: "",
    MeterName: "",
    ProductName: "",
  };
}

function isCacheFresh(record: PricingCacheRecord): boolean {
  return new Date(record.expiresAt).getTime() > Date.now();
}

function isPrimaryMeter(item: RetailPriceItem): boolean {
  if (item.isPrimaryMeterRegion === null || item.isPrimaryMeterRegion === undefined) {
    return true;
  }

  if (typeof item.isPrimaryMeterRegion === "boolean") {
    return item.isPrimaryMeterRegion;
  }

  return String(item.isPrimaryMeterRegion).toLowerCase() === "true";
}

function getPriceDescriptorText(item: RetailPriceItem): string {
  return [item.armSkuName, item.skuName, item.productName, item.meterName]
    .filter(Boolean)
    .join(" ")
    .trim();
}

function isVmAddonPrice(item: RetailPriceItem): boolean {
  return /Spot|Low Priority|Dedicated Host|SQL|BizTalk|Visual Studio|Oracle/i.test(
    getPriceDescriptorText(item),
  );
}

function isLinuxLicensedPrice(item: RetailPriceItem): boolean {
  return /Red Hat|RedHat|RHEL|SUSE|Ubuntu Pro/i.test(
    getPriceDescriptorText(item),
  );
}

function hasWindowsLicenseBenefit(osType: string, licenseType?: string): boolean {
  if (osType !== "Windows") {
    return false;
  }

  const normalized = licenseType?.trim().toLowerCase();
  if (!normalized) {
    return false;
  }

  return /windows|hybrid/.test(normalized);
}

function selectPriceMatch(
  items: RetailPriceItem[],
  priceType: string,
  osType: string,
  armSkuName: string,
  reservationTerm: string,
): PriceMatch | undefined {
  const candidates = items.filter((item) => {
    if (item.type !== priceType) {
      return false;
    }

    if (!isPrimaryMeter(item)) {
      return false;
    }

    if (/Spot|Low Priority/i.test(String(item.meterName || ""))) {
      return false;
    }

    if (/Spot|Low Priority/i.test(String(item.skuName || ""))) {
      return false;
    }

    if (priceType === "Consumption" && item.unitOfMeasure !== "1 Hour") {
      return false;
    }

    if (reservationTerm && item.reservationTerm !== reservationTerm) {
      return false;
    }

    return true;
  });

  const scored = candidates
    .map((item) => {
      if (isVmAddonPrice(item)) {
        return undefined;
      }

      const text = getPriceDescriptorText(item);
      const isWindowsTagged = /\bWindows\b/i.test(text);
      const linuxLicensed = isLinuxLicensedPrice(item);
      const genericBase = !isWindowsTagged && !linuxLicensed;
      let score = 0;
      let matchType = "Unmatched";

      if (String(item.armSkuName || "") === armSkuName) {
        score += 200;
      }

      if (priceType === "Consumption") {
        if (osType === "Windows") {
          if (isWindowsTagged) {
            score += 120;
            matchType = "WindowsTagged";
          } else if (genericBase) {
            score += 70;
            matchType = "GenericBaseFallback";
          } else {
            return undefined;
          }
        } else {
          if (isWindowsTagged || linuxLicensed) {
            return undefined;
          }

          score += 120;
          matchType = "BaseCompute";
        }
      } else if (osType === "Windows") {
        if (isWindowsTagged) {
          score += 110;
          matchType = "WindowsReservation";
        } else if (genericBase) {
          score += 100;
          matchType = "GenericReservationFallback";
        } else {
          return undefined;
        }
      } else {
        if (isWindowsTagged || linuxLicensed) {
          return undefined;
        }

        score += 110;
        matchType = "BaseReservation";
      }

      if (/Virtual Machines/i.test(String(item.productName || ""))) {
        score += 10;
      }

      return {
        item,
        matchType,
        score,
      };
    })
    .filter((candidate): candidate is NonNullable<typeof candidate> => Boolean(candidate))
    .sort((left, right) => {
      if (right.score !== left.score) {
        return right.score - left.score;
      }

      return Number(left.item.retailPrice || 0) - Number(right.item.retailPrice || 0);
    });

  if (scored.length === 0) {
    return undefined;
  }

  return {
    item: scored[0].item,
    matchType: scored[0].matchType,
  };
}

async function invokeRetailPriceQuery(filter: string): Promise<RetailPriceItem[]> {
  let requestUri = `${RETAIL_PRICES_BASE_URI}&$filter=${encodeURIComponent(filter)}`;
  const items: RetailPriceItem[] = [];

  while (requestUri) {
    const response = await fetch(requestUri);
    if (!response.ok) {
      throw new Error(`Retail prices API request failed with status ${response.status}`);
    }

    const payload = (await response.json()) as RetailPriceApiResponse;
    if (payload.Items) {
      items.push(...payload.Items);
    }

    requestUri = payload.NextPageLink || "";
  }

  return items;
}

function buildPricingModel(
  request: PricingLookupRequest,
  items: RetailPriceItem[],
): PricingModel {
  const includeOsLicense =
    request.osType === "Windows" &&
    !hasWindowsLicenseBenefit(request.osType, request.licenseType);

  const basePaygSelection = selectPriceMatch(
    items,
    "Consumption",
    "Linux",
    request.armSkuName,
    "",
  );
  const windowsPaygSelection =
    request.osType === "Windows"
      ? selectPriceMatch(
          items,
          "Consumption",
          "Windows",
          request.armSkuName,
          "",
        )
      : basePaygSelection;

  const ri1BaseSelection = selectPriceMatch(
    items,
    "Reservation",
    "Linux",
    request.armSkuName,
    "1 Year",
  );
  const ri3BaseSelection = selectPriceMatch(
    items,
    "Reservation",
    "Linux",
    request.armSkuName,
    "3 Years",
  );
  const ri1Selection =
    request.osType === "Windows"
      ? selectPriceMatch(
          items,
          "Reservation",
          "Windows",
          request.armSkuName,
          "1 Year",
        )
      : ri1BaseSelection;
  const ri3Selection =
    request.osType === "Windows"
      ? selectPriceMatch(
          items,
          "Reservation",
          "Windows",
          request.armSkuName,
          "3 Years",
        )
      : ri3BaseSelection;

  const basePayg = basePaygSelection?.item;
  const windowsPayg = windowsPaygSelection?.item;
  const ri1Base = ri1BaseSelection?.item;
  const ri3Base = ri3BaseSelection?.item;
  const ri1 = ri1Selection?.item;
  const ri3 = ri3Selection?.item;

  const basePaygHourly = Number(basePayg?.retailPrice || 0);
  const windowsPaygHourly = Number(windowsPayg?.retailPrice || 0);
  const basePaygMonthly = basePaygHourly > 0 ? Math.round(basePaygHourly * 730 * 100) / 100 : 0;

  let osLicenseHourly = 0;
  let osLicenseStatus = request.osType !== "Windows" ? "NotApplicable" : includeOsLicense ? "EstimateUnavailable" : "ExcludedByLicenseBenefit";

  if (
    includeOsLicense &&
    windowsPaygSelection?.matchType === "WindowsTagged" &&
    windowsPaygHourly > basePaygHourly
  ) {
    osLicenseHourly = Math.round(Math.max(windowsPaygHourly - basePaygHourly, 0) * 1_000_000) / 1_000_000;
    osLicenseStatus = "DerivedFromWindowsConsumptionDelta";
  }

  const osLicenseMonthly =
    osLicenseHourly > 0 ? Math.round(osLicenseHourly * 730 * 100) / 100 : 0;

  let paygHourly = 0;
  if (includeOsLicense) {
    if (windowsPaygHourly > 0) {
      paygHourly = windowsPaygHourly;
    } else if (basePaygHourly > 0 && osLicenseHourly > 0) {
      paygHourly = basePaygHourly + osLicenseHourly;
    } else {
      paygHourly = basePaygHourly;
    }
  } else if (basePaygHourly > 0) {
    paygHourly = basePaygHourly;
  } else {
    paygHourly = windowsPaygHourly;
  }

  const paygMonthly = paygHourly > 0 ? Math.round(paygHourly * 730 * 100) / 100 : 0;
  const ri1BaseMonthly = ri1Base?.retailPrice ? Math.round((Number(ri1Base.retailPrice) / 12) * 100) / 100 : 0;
  const ri3BaseMonthly = ri3Base?.retailPrice ? Math.round((Number(ri3Base.retailPrice) / 36) * 100) / 100 : 0;
  const ri1RawMonthly = ri1?.retailPrice ? Math.round((Number(ri1.retailPrice) / 12) * 100) / 100 : 0;
  const ri3RawMonthly = ri3?.retailPrice ? Math.round((Number(ri3.retailPrice) / 36) * 100) / 100 : 0;

  const ri1Monthly = includeOsLicense
    ? ri1Selection?.matchType === "WindowsReservation"
      ? ri1RawMonthly
      : ri1BaseMonthly > 0
        ? Math.round((ri1BaseMonthly + osLicenseMonthly) * 100) / 100
        : ri1RawMonthly
    : ri1BaseMonthly > 0
      ? ri1BaseMonthly
      : ri1RawMonthly;

  const ri3Monthly = includeOsLicense
    ? ri3Selection?.matchType === "WindowsReservation"
      ? ri3RawMonthly
      : ri3BaseMonthly > 0
        ? Math.round((ri3BaseMonthly + osLicenseMonthly) * 100) / 100
        : ri3RawMonthly
    : ri3BaseMonthly > 0
      ? ri3BaseMonthly
      : ri3RawMonthly;

  let pricingStatus = "OK";
  if (paygMonthly <= 0) {
    pricingStatus = "PAYG meter not found";
  } else if (ri1Monthly <= 0 && ri3Monthly <= 0) {
    pricingStatus = "RI meters not found";
  } else if (ri1Monthly <= 0) {
    pricingStatus = "1YR RI not found";
  } else if (ri3Monthly <= 0) {
    pricingStatus = "3YR RI not found";
  }

  const currencyCode =
    windowsPayg?.currencyCode ||
    basePayg?.currencyCode ||
    ri1?.currencyCode ||
    ri3?.currencyCode ||
    "USD";

  return {
    CurrencyCode: currencyCode,
    PaygHourly: Math.round(paygHourly * 1_000_000) / 1_000_000,
    PaygMonthly: paygMonthly,
    PaygComputeMonthly: basePaygMonthly,
    Reservation1YearTotal: ri1Base?.retailPrice ? Math.round(Number(ri1Base.retailPrice) * 100) / 100 : ri1?.retailPrice ? Math.round(Number(ri1.retailPrice) * 100) / 100 : 0,
    Reservation1YearMonthly: ri1Monthly,
    Reservation1YearComputeMonthly: ri1BaseMonthly,
    Reservation3YearTotal: ri3Base?.retailPrice ? Math.round(Number(ri3Base.retailPrice) * 100) / 100 : ri3?.retailPrice ? Math.round(Number(ri3.retailPrice) * 100) / 100 : 0,
    Reservation3YearMonthly: ri3Monthly,
    Reservation3YearComputeMonthly: ri3BaseMonthly,
    IncludeOsLicense: includeOsLicense,
    LicenseBenefitApplied:
      !includeOsLicense &&
      request.osType === "Windows" &&
      hasWindowsLicenseBenefit(request.osType, request.licenseType),
    OsLicenseHourly: osLicenseHourly,
    OsLicenseMonthly: osLicenseMonthly,
    OsLicenseStatus: osLicenseStatus,
    PricingStatus: pricingStatus,
    PaygMatchType: windowsPaygSelection?.matchType || basePaygSelection?.matchType || "",
    Reservation1YearMatchType: ri1Selection?.matchType || "",
    Reservation3YearMatchType: ri3Selection?.matchType || "",
    MeterName: String(windowsPayg?.meterName || basePayg?.meterName || ""),
    ProductName: String(windowsPayg?.productName || basePayg?.productName || ""),
  };
}

function createPricingCacheEntity(
  request: PricingLookupRequest,
  model: PricingModel,
  fetchedAt: string,
  expiresAt: string,
  source: string,
): PricingCacheEntity {
  const normalized = normalizeLookupRequest(request);
  const keyParts = getPricingKeyParts(normalized);

  return {
    partitionKey: keyParts.partitionKey,
    rowKey: keyParts.rowKey,
    armRegionName: normalized.armRegionName,
    armSkuName: normalized.armSkuName,
    osType: normalized.osType,
    licenseType: normalized.licenseType,
    licenseMode: keyParts.licenseMode,
    fetchedAt,
    expiresAt,
    source,
    ...model,
  };
}

export async function getCachedPricingModel(
  request: PricingLookupRequest,
): Promise<PricingCacheRecord | null> {
  const normalized = normalizeLookupRequest(request);
  const keyParts = getPricingKeyParts(normalized);
  const entity = await getPricingCacheEntity(keyParts.partitionKey, keyParts.rowKey);
  if (!entity) {
    return null;
  }

  return buildCacheRecord(normalized, entity, "Hit");
}

export async function enqueueTargetedPricingRefresh(
  request: PricingLookupRequest,
  reason: PricingRefreshReason,
): Promise<void> {
  const normalized = normalizeLookupRequest(request);
  const message: PricingRefreshQueueMessage = {
    ...normalized,
    reason,
    requestedAt: new Date().toISOString(),
  };

  await enqueuePricingRefresh(message);
}

export async function refreshPricingModel(
  request: PricingLookupRequest,
  reason: PricingRefreshReason,
): Promise<PricingCacheRecord> {
  const normalized = normalizeLookupRequest(request);
  const filter =
    `serviceName eq 'Virtual Machines' and armRegionName eq '${normalized.armRegionName}' ` +
    `and armSkuName eq '${normalized.armSkuName}'`;

  let model: PricingModel;
  try {
    const items = await invokeRetailPriceQuery(filter);
    model = buildPricingModel(normalized, items);
  } catch {
    const fallback = createFallbackPricingModel();
    const now = new Date().toISOString();
    return {
      key: getPricingKeyParts(normalized).key,
      lookup: normalized,
      model: fallback,
      cacheStatus: "Live",
      fetchedAt: now,
      expiresAt: now,
    };
  }

  const now = new Date();
  const fetchedAt = now.toISOString();
  const expiresAt = new Date(
    now.getTime() + getAppSettings().pricingCacheMaxAgeMinutes * 60 * 1000,
  ).toISOString();
  const entity = createPricingCacheEntity(normalized, model, fetchedAt, expiresAt, reason);

  await upsertPricingCacheEntity(entity);
  return buildCacheRecord(normalized, entity, "Live");
}

export async function getPricingModel(
  request: PricingLookupRequest,
  options: GetPricingModelOptions = {},
): Promise<PricingCacheRecord> {
  const cached = await getCachedPricingModel(request);
  if (cached && isCacheFresh(cached)) {
    return cached;
  }

  if (!cached && options.enqueueRefreshOnMiss !== false) {
    try {
      await enqueueTargetedPricingRefresh(request, "CacheMiss");
    } catch {
      // Do not fail the current lookup if background refresh could not be queued.
    }
  }

  if (cached && !isCacheFresh(cached)) {
    const refreshed = await refreshPricingModel(request, "Stale");
    return refreshed;
  }

  return refreshPricingModel(request, "CacheMiss");
}
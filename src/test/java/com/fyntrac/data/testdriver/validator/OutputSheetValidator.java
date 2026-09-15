package com.fyntrac.data.testdriver.validator;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.bson.Document;
import org.junit.jupiter.api.Assertions;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.domain.Sort;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.data.mongodb.core.query.Criteria;
import org.springframework.data.mongodb.core.query.Query;

import java.io.InputStream;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.*;
public class OutputSheetValidator {

    private static final Logger log = LoggerFactory.getLogger(OutputSheetValidator.class);
    private final MongoTemplate mongoTemplate;
    private final ObjectMapper objectMapper = new ObjectMapper();
    private FormulaEvaluator formulaEvaluator;
    public OutputSheetValidator(MongoTemplate mongoTemplate) {
        this.mongoTemplate = mongoTemplate;
        this.formulaEvaluator = null;
    }

    public void validate(InputStream fileStream) throws Exception {
        List<String> allFailures = new ArrayList<>();
        try (Workbook workbook = new XSSFWorkbook(fileStream)) {
            this.formulaEvaluator = workbook.getCreationHelper().createFormulaEvaluator();
            for (Sheet sheet : workbook) {
                if (!sheet.getSheetName().toLowerCase().startsWith("o_")) continue;

                try {
                    String collectionName = getStringCell(sheet.getRow(0).getCell(0));
                    String jsonQuery = getStringCell(sheet.getRow(0).getCell(1));

                    List<String> columns = new ArrayList<>();
                    Map<String, Sort.Direction> sortMap = new LinkedHashMap<>();

                    for (Cell cell : sheet.getRow(1)) {
                        String header = getStringCell(cell);
                        if (header == null || header.isBlank()) continue;

                        String[] parts = header.trim().split("\\s+");
                        String columnName = parts[0];
                        columns.add(columnName);

                        if (parts.length > 1 && (parts[1].equalsIgnoreCase("ASC") || parts[1].equalsIgnoreCase("DESC"))) {
                            Sort.Direction direction = parts[1].equalsIgnoreCase("DESC") ? Sort.Direction.DESC : Sort.Direction.ASC;
                            sortMap.put(columnName, direction);
                        }
                    }

                    Query query = buildQuery(jsonQuery, columns, sortMap);
                    System.out.printf("Sheet [%s], validation Query[%s]", sheet.getSheetName(), query.toString());
                    List<Document> actualResults = mongoTemplate.find(query, Document.class, collectionName);

                    List<Map<String, Object>> expectedRows = new ArrayList<>();
                    for (int i = 2; i <= sheet.getLastRowNum(); i++) {
                        Row row = sheet.getRow(i);
                        if (row == null || isRowEmpty(row)) continue;

                        Map<String, Object> rowMap = new LinkedHashMap<>();
                        for (int j = 0; j < columns.size(); j++) {
                            Cell cell = row.getCell(j);
                            Object value = parseCellValue(cell);
                            rowMap.put(columns.get(j), value);
                        }
                        expectedRows.add(rowMap);
                    }


                    log.info("Sheet: {} - Expected: {} rows, Actual: {} rows",
                            sheet.getSheetName(), expectedRows.size(), actualResults.size());

                    int issues = 0;
                    StringBuilder misMatchBuilder = new StringBuilder();

                    if (expectedRows.size() != actualResults.size()) {
                        String rowCountMsg = String.format("❌ Row count mismatch in sheet '%s': expected %d, found %d",
                                sheet.getSheetName(), expectedRows.size(), actualResults.size());
                        log.error(rowCountMsg);
                        misMatchBuilder.append(rowCountMsg).append("\n");
                        issues++;
                    } else {
                        log.info("✅ Row count matched in sheet '{}'", sheet.getSheetName());
                    }

                    // Bound by the shorter list so a row-count mismatch can't crash
                    // the comparison loop with an IndexOutOfBoundsException - the
                    // count mismatch itself is already recorded as an issue above.
                    int rowsToCompare = Math.min(expectedRows.size(), actualResults.size());
                    for (int i = 0; i < rowsToCompare; i++) {
                        Map<String, Object> expected = expectedRows.get(i);
                        Document actualDoc = actualResults.get(i);
                        Map<String, Object> actual = flattenDocument(actualDoc);

                        for (String column : columns) {
                            Object expectedVal = expected.get(column); // getNestedValue(expected, column);
                            Object actualVal = actual.get(column); // getNestedValue(actual, column);

                            boolean equal = compareValues(expectedVal, actualVal);

                            if (!equal) {
                                issues++;
                                String message = String.format("❌ Mismatch at row %d, column '%s' - expected: [%s], actual: [%s]",
                                        i + 3, column, expectedVal, actualVal);
                                log.error(message);
                                misMatchBuilder.append(message).append("\n");
                            }
                        }
                    }

                    if (issues == 0) {
                        log.info("✅ Sheet '{}' matched all rows and columns", sheet.getSheetName());
                    } else {
                        String misMatchStr = String.format("❌ Sheet '%s' had %d issue(s)", sheet.getSheetName(), issues);
                        log.error(misMatchStr);
                        allFailures.add(String.format("Error[%s]: Details[%s]", misMatchStr, misMatchBuilder));
                    }
                } catch (Exception e) {
                    String failureMsg = String.format("Exception occurred while validating sheet '%s': %s",
                            sheet.getSheetName(), e.getMessage());
                    log.error(failureMsg, e);
                    allFailures.add(failureMsg);
                }
            }
        } catch (Exception e) {
            log.error("Error reading workbook: {}", e.getMessage(), e);
            throw e;
        }

        if (!allFailures.isEmpty()) {
            Assertions.fail("Data validation failed for " + allFailures.size()
                    + " sheet(s):\n" + String.join("\n", allFailures));
        }
    }

    private boolean isRowEmpty(Row row) {
        for (int c = row.getFirstCellNum(); c < row.getLastCellNum(); c++) {
            Cell cell = row.getCell(c);
            if (cell != null && cell.getCellType() != CellType.BLANK && !cell.toString().trim().isEmpty()) {
                return false;
            }
        }
        return true;
    }

    private Query buildQuery(String jsonQuery,
                             List<String> includedFields,
                             Map<String, Sort.Direction> sortMap) {

        log.warn("⏳ RAW INPUT QUERY: {}", jsonQuery);

        // --- Fix curly quotes if present ---
        jsonQuery = jsonQuery.replace("‘", "\"")
                .replace("’", "\"")
                .replace("“", "\"")
                .replace("”", "\"");

        Document criteriaDoc = Document.parse(jsonQuery);

        Query query = new Query();

        log.warn("📌 Parsed Criteria Document: {}", criteriaDoc.toJson());

        // --- Apply Criteria ---
        for (Map.Entry<String, Object> entry : criteriaDoc.entrySet()) {
            if (!entry.getKey().equalsIgnoreCase("collection")) {
                query.addCriteria(Criteria.where(entry.getKey()).is(entry.getValue()));
            }
        }

        // ---------------------------------------------------------
        // FIX: Always include _id to prevent MongoDB from dropping rows
        // ---------------------------------------------------------
        query.fields().include("_id");

        // --- Apply Field Projections Only if Present ---
        if (includedFields != null && !includedFields.isEmpty()) {
            includedFields.forEach(f -> {
                // log.warn("📌 Including field in projection: {}", f);
                query.fields().include(f);
            });
        }

        // --- Sorting ---
        if (sortMap != null && !sortMap.isEmpty()) {
            Sort sort = Sort.by(sortMap.entrySet().stream()
                    .map(e -> new Sort.Order(e.getValue(), e.getKey()))
                    .toList());
            query.with(sort);
        }

        // --- LOG EVERYTHING ---
        log.warn("🧾 FINAL QUERY FILTER: {}", query.getQueryObject());
        log.warn("🧾 FINAL QUERY FIELDS: {}", query.getFieldsObject());
        log.warn("🧾 FINAL SORT: {}", query.getSortObject());

        return query;
    }


    private String getStringCell(Cell cell) {
        if (cell == null) return null;
        return cell.getCellType() == CellType.STRING ? cell.getStringCellValue().trim() : cell.toString().trim();
    }

    private Object parseCellValue(Cell cell) {
        if (cell == null) return null;

        CellType cellType = cell.getCellType();
        if (cellType == CellType.FORMULA) {
            cellType = formulaEvaluator.evaluateFormulaCell(cell);
        }

        return switch (cellType) {
            case STRING -> {
                String val = cell.getStringCellValue().trim();
                if (val.equalsIgnoreCase("true") || val.equalsIgnoreCase("false")) {
                    yield Boolean.parseBoolean(val);
                }
                try {
                    yield new BigDecimal(val);
                } catch (Exception e) {
                    yield val;
                }
            }
            case NUMERIC -> {
                if (DateUtil.isCellDateFormatted(cell)) {
                    yield cell.getDateCellValue();
                } else {
                    BigDecimal num = BigDecimal.valueOf(cell.getNumericCellValue());
                    yield num.scale() > 0 ? num : num.longValue();
                }
            }
            case BOOLEAN -> cell.getBooleanCellValue();
            case BLANK -> null;
            default -> cell.toString().trim();
        };
    }


    private Object parseExcelValue(String value, String columnType) {
        try {
            return switch (columnType.toLowerCase()) {
                case "string" -> value.trim();
                case "bigdecimal" -> new BigDecimal(value.trim());
                case "double" -> Double.parseDouble(value.trim());
                case "long" -> Long.parseLong(value.trim());
                case "boolean" -> Boolean.parseBoolean(value.trim().toLowerCase());
                case "date" -> {
                    LocalDate date = LocalDate.parse(value.trim(), DateTimeFormatter.ofPattern("MM/dd/yyyy"));
                    yield Date.from(date.atStartOfDay(ZoneOffset.UTC).toInstant());
                }
                default -> value.trim();
            };
        } catch (Exception e) {
            log.warn("Failed to parse value '{}' as type '{}', returning as String", value, columnType);
            return value.trim();
        }
    }

    private Object getNestedValue(Map<String, Object> map, String keyPath) {
        String[] keys = keyPath.split("\\.");
        Object value = map;
        for (String key : keys) {
            if (!(value instanceof Map)) return null;
            value = ((Map<String, Object>) value).get(key);
        }
        return value;
    }

    private boolean compareValues(Object expected, Object actual) {
        // Treat null and empty string as equal
        if (isNullOrEmpty(expected) && isNullOrEmpty(actual)) return true;

        try {
            if (expected instanceof BigDecimal || actual instanceof BigDecimal) {
                BigDecimal e = new BigDecimal(expected.toString()).setScale(4, RoundingMode.HALF_UP);
                BigDecimal a = new BigDecimal(actual.toString()).setScale(4, RoundingMode.HALF_UP);
                return e.compareTo(a) == 0;
            }

            if (expected instanceof Number && actual instanceof Number) {
                return new BigDecimal(expected.toString()).compareTo(new BigDecimal(actual.toString())) == 0;
            }

            // Date or ISO String date comparison
            if ((expected instanceof Date || isIsoDateString(expected)) &&
                    (actual instanceof Date || isIsoDateString(actual))) {

                Instant expectedInstant = expected instanceof Date
                        ? ((Date) expected).toInstant()
                        : Instant.parse(expected.toString());

                Instant actualInstant = actual instanceof Date
                        ? ((Date) actual).toInstant()
                        : Instant.parse(actual.toString());

                LocalDate expectedDate = expectedInstant.atZone(ZoneOffset.UTC).toLocalDate();
                LocalDate actualDate = actualInstant.atZone(ZoneOffset.UTC).toLocalDate();

                return expectedDate.equals(actualDate);
            }

            if (expected instanceof Boolean || actual instanceof Boolean) {
                return Boolean.parseBoolean(expected.toString()) == Boolean.parseBoolean(actual.toString());
            }

            return expected.toString().trim().equals(actual.toString().trim());

        } catch (Exception e) {
            log.warn("Comparison failed between expected [{}] and actual [{}]: {}", expected, actual, e.getMessage());
            return false;
        }
    }

    private boolean isNullOrEmpty(Object obj) {
        return obj == null || (obj instanceof String && ((String) obj).trim().isEmpty());
    }


    private boolean isIsoDateString(Object obj) {
        if (!(obj instanceof String)) return false;
        String s = ((String) obj).trim();
        return s.matches("\\d{4}-\\d{2}-\\d{2}T.*Z"); // rough ISO 8601 UTC format
    }


    private Map<String, Object> flattenDocument(Document doc) {
        Map<String, Object> flatMap = new LinkedHashMap<>();
        flatten("", doc, flatMap);
        return flatMap;
    }

    private void flatten(String prefix, Map<String, Object> source, Map<String, Object> target) {
        for (Map.Entry<String, Object> entry : source.entrySet()) {
            String key = prefix.isEmpty() ? entry.getKey() : prefix + "." + entry.getKey();
            Object value = entry.getValue();

            if (value instanceof Document) {
                flatten(key, ((Document) value), target);
            } else if (value instanceof Map) {
                flatten(key, (Map<String, Object>) value, target);
            } else {
                target.put(key, value);
            }
        }
    }
}

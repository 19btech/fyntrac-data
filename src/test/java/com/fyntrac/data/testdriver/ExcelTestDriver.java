package com.fyntrac.data.testdriver;

import com.fyntrac.common.component.TenantDataSourceProvider;
import com.fyntrac.common.dto.record.RecordFactory;
import com.fyntrac.common.dto.record.Records;
import com.fyntrac.common.entity.Model;
import com.fyntrac.common.entity.Settings;
import com.fyntrac.common.enums.AggregationLevel;
import com.fyntrac.common.enums.ModelStatus;
import com.fyntrac.common.enums.TestStep;
import com.fyntrac.common.repository.MemcachedRepository;
import com.fyntrac.common.service.DataService;
import com.fyntrac.data.testdriver.validator.OutputSheetValidator;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.data.mongodb.core.MongoTemplate;
import org.springframework.http.*;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;

import java.io.ByteArrayOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Properties;

import static org.springframework.test.util.AssertionErrors.assertNotNull;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.DEFINED_PORT) // must match 8089
public class ExcelTestDriver {

    @Autowired
    private TestRestTemplate restTemplate;

    private String tenantId;
    private static final String TEST_TENANT_ID_PROPERTY_NAME = "test.tenantId";
    private static final String TEST_STEP_FILE= "test.steps.file";
    private static final String TEST_DATA_FOLDER= "testData";
    private static final String TEST_ACCOUNTING_PERIOD_START_DATE="test.accounting.period.start";
    private static final String TEST_DATALOADER_URI_PROPERTY="test.dataloader.uri";
    private static final String TES_MODEL_URI_PROPERTY="test.model.uri=http";
    private static String testData;
    private static String dataLoaderURI;
    private static String modelURI;
    Properties properties = new Properties();
    @Autowired
    private DataService dataService;

    @Autowired
    private MemcachedRepository memcachedRepository;
    @Autowired
    private TenantDataSourceProvider dataSourceProvider;
    private Model model;

    @BeforeEach
    public void setUp() throws Throwable {
        testData = System.getProperty(TEST_DATA_FOLDER);
        if (testData == null || testData.isEmpty()) {
            throw new FileNotFoundException("System property 'testData' must be set (e.g., -DtestData=TestSBO)");
        }



        String propertyFile = String.format("%s/%s",testData,"test.properties");
        InputStream propertiesFileStram = this.readFile(propertyFile);
        properties.load(propertiesFileStram);

        // Load required property
        tenantId = properties.getProperty(TEST_TENANT_ID_PROPERTY_NAME);
        if (tenantId == null || tenantId.isEmpty()) {
            throw new IllegalStateException("Missing required property: " + TEST_TENANT_ID_PROPERTY_NAME);
        }
        this.dataService.truncateDatabase(tenantId);

        dataLoaderURI= properties.getProperty(TEST_DATALOADER_URI_PROPERTY);
        modelURI = properties.getProperty(TES_MODEL_URI_PROPERTY);

        String strDate = properties.getProperty(TEST_ACCOUNTING_PERIOD_START_DATE);
        Date accountingPeriodDate = com.fyntrac.common.utils.DateUtil.parseDate(strDate, DateTimeFormatter.ofPattern("MM/dd/yyyy"));
        generateAccountingPeriod(accountingPeriodDate);
        // this.dataService.setTenantId(tenantId);
        this.model=null;
        String testingKey = String.format("TesingKey%d", System.currentTimeMillis());
        memcachedRepository.putInCache(testingKey, "Testing Started", 200);
        // Optional: wait a bit to ensure Memcached is ready (only needed for test environment)
        Thread.sleep(5000); // Increase if your system is slow
        String testValue = (String) memcachedRepository.getFromCache(testingKey);
        assertNotNull(testValue, "Memcached did not return value after putInCache");
    }

    @Test
    public void testApiEndpoints() throws Throwable {

        assertNotNull(tenantId, "Tenant ID must be initialized in setup");
        executeSteps();
        // Sample API call (replace with your actual logic)
        // ResponseEntity<String> response = restTemplate.getForEntity(
        //        "/api/someEndpoint?tenantId={tenantId}",
        //        String.class,
        //        tenantId);
        //
        // assertEquals("Expected 200 OK", HttpStatus.OK, response.getStatusCode());
    }

    private void executeSteps() throws Throwable {
        String testFile = String.format("%s/%s",testData,this.properties.getProperty(TEST_STEP_FILE));
        InputStream fileStream = this.readFile(testFile);
        List<Records.ExcelTestStepRecord> steps = readTestSteps(fileStream);

        for(Records.ExcelTestStepRecord step : steps) {
            executeStep(step);
        }

        // Add 10-second delay
        try {
            Thread.sleep(50_000); // 10,000 milliseconds = 10 seconds
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt(); // Restore interrupt status
            throw new RuntimeException("Thread was interrupted during sleep", e);
        }

        //Validate output
        MongoTemplate mongoTemplate =  this.dataSourceProvider.getDataSource(tenantId);

        OutputSheetValidator outputSheetValidator = new OutputSheetValidator(mongoTemplate);
        try {
            outputSheetValidator.validate(this.readFile(testFile));
        }catch (RuntimeException e){
            Assertions.fail("Data comparision failed: " + e.getMessage(), e);
        }
    }

    private void executeStep(Records.ExcelTestStepRecord step) throws Throwable {
        try {
            TestStep testStep = step.step();
            if (testStep == TestStep.LOAD_REF_DATA) {
                loadData(step.input());
            } else if (testStep == TestStep.ACTIVITY_UPLOAD) {
                //Upload Activity method
                loadData(step.input());
            } else if (testStep == TestStep.MODEL_UPLOAD) {
                model = uploadModel(step.input());
            } else if (testStep == TestStep.MODEL_CONFIGURATION) {
                model.getModelConfig().setAggregationLevel(AggregationLevel.valueOf(step.input()));
                model.getModelConfig().setCurrentVersion(Boolean.TRUE);
                model.setModelStatus(ModelStatus.ACTIVE);
                configureModel(model);
            } else if (testStep == TestStep.MODEL_EXECUTION) {
                //Model execution
                String executionDate = step.input();
                executeModel(executionDate);

                // Add 10-second delay
                try {
                    Thread.sleep(30_000); // 10,000 milliseconds = 10 seconds
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt(); // Restore interrupt status
                    throw new RuntimeException("Thread was interrupted during sleep", e);
                }
            }
        }catch (Exception e){
            throw e;
        }


    }

    private InputStream readFile(String fileName) throws IOException{

        String testResourcePath = String.format("TestDriver/%s", fileName);
        ClassPathResource resource = new ClassPathResource(testResourcePath);

        if (!resource.exists()) {
            throw new FileNotFoundException("Test properties not found at: " + testResourcePath);
        }

       return resource.getInputStream();
    }

    private void loadData(String dataFile) throws IOException {
        InputStream fileStream = this.readFile(dataFile);
        InputStream[] streams = new InputStream[1];
        String[] fileNames = new String[1];
        streams[0] = fileStream;
        fileNames[0] = "dataFile.xlsx";
        uploadFiles(streams, fileNames);
    }

    private void generateAccountingPeriod(Date fiscalPeriodStartDate) {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.set("X-Tenant", tenantId); // if needed

        Settings settings = Settings.builder()
                .fiscalPeriodStartDate(fiscalPeriodStartDate)
                .glamFields("")
                .homeCurrency("")
                .reportingPeriod(null)
                .restatementMode(0)
                .id(null)
                .build();

        String url = String.format("%s/%s", dataLoaderURI, "/setting/fiscal-priod/save");
        HttpEntity<Settings> requestEntity = new HttpEntity<>(settings, headers);

        ResponseEntity<String> response = restTemplate.postForEntity(url, requestEntity, String.class);

        Assertions.assertEquals(HttpStatus.OK, response.getStatusCode());
    }

    private void uploadFiles(InputStream[] streams, String[] filenames) {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.MULTIPART_FORM_DATA);
        headers.set("X-Tenant", tenantId); // optional if you need tenant info

        MultiValueMap<String, Object> body = new LinkedMultiValueMap<>();

        for (int i = 0; i < streams.length; i++) {
            NamedInputStreamResource resource = new NamedInputStreamResource(streams[i], filenames[i]);
            body.add("files", resource); // "files" must match your @RequestParam name
        }

        HttpEntity<MultiValueMap<String, Object>> requestEntity = new HttpEntity<>(body, headers);
        String uri = String.format("%s/%s", dataLoaderURI,"accounting/rule/upload");
        ResponseEntity<String> response = restTemplate.postForEntity(uri, requestEntity, String.class);

        Assertions.assertEquals(200, response.getStatusCodeValue(), "File upload failed");
    }

    Model uploadModel(String modelFile) throws Exception {
        String uri = String.format("%s/%s", dataLoaderURI, "model/upload" );

         InputStream fileStream = this.readFile(modelFile);

        // Prepare file content
        byte[] content = ExcelTestDriver.toByteArray(fileStream);
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.MULTIPART_FORM_DATA);
        headers.set("X-Tenant", tenantId);

        MultiValueMap<String, Object> body = new LinkedMultiValueMap<>();
        body.add("files", new ByteArrayResource(content) {
            @Override
            public String getFilename() {
                return String.format("%s.%s", modelFile, "xlsx");
            }
        });
        body.add("modelName", "TestModel");
        body.add("modelOrderId", "1");

        HttpEntity<MultiValueMap<String, Object>> requestEntity = new HttpEntity<>(body, headers);

        ResponseEntity<Model> response = restTemplate.postForEntity(uri, requestEntity, Model.class);

        Assertions.assertEquals(HttpStatus.OK, response.getStatusCode());
        return response.getBody();
        // Optionally assert response body
    }

    Model configureModel(Model model) throws Exception {
        String uri = String.format("%s/%s", dataLoaderURI, "model/configure" );

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.set("X-Tenant", tenantId); // if needed

        HttpEntity<Model> requestEntity = new HttpEntity<>(model, headers);
        ResponseEntity<Model> response = restTemplate.postForEntity(uri, requestEntity, Model.class);

        Assertions.assertEquals(HttpStatus.OK, response.getStatusCode());
        return response.getBody();
        // Optionally assert response body
    }

    void executeModel(String executionDate) throws Throwable {
        String uri = String.format("%s/%s", dataLoaderURI, "model/execute" );

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.set("X-Tenant", tenantId); // if needed

        Date accountingPeriodDate = com.fyntrac.common.utils.DateUtil.parseDate(executionDate, DateTimeFormatter.ofPattern("yyyy-MM-dd"));
        String strDate = com.fyntrac.common.utils.DateUtil.format(accountingPeriodDate, "MM/dd/yyyy");
        Records.DateRequestRecord dateRequestRecord = RecordFactory.createDateRequest(strDate);
        HttpEntity<Records.DateRequestRecord> requestEntity = new HttpEntity<>(dateRequestRecord, headers);
        ResponseEntity<String> response = restTemplate.postForEntity(uri, requestEntity, String.class);

        Assertions.assertEquals(HttpStatus.OK, response.getStatusCode());
        // Optionally assert response body
    }

    public static byte[] toByteArray(InputStream input) throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        byte[] data = new byte[4096]; // 4 KB buffer
        int nRead;
        while ((nRead = input.read(data, 0, data.length)) != -1) {
            buffer.write(data, 0, nRead);
        }
        buffer.flush();
        return buffer.toByteArray();
    }

    public  List<Records.ExcelTestStepRecord> readTestSteps(InputStream inputStream) throws IOException {
        List<Records.ExcelTestStepRecord> records = new ArrayList<>();

        try (Workbook workbook = new XSSFWorkbook(inputStream)) {
            Sheet sheet = workbook.getSheetAt(0);
            boolean isHeader = true;

            for (Row row : sheet) {
                if (isHeader) {
                    isHeader = false;
                    continue; // Skip header
                }

                String step = getCellValue(row.getCell(0));
                String type = getCellValue(row.getCell(1));
                String input = getCellValue(row.getCell(2));

                // Skip row if all fields are blank
                if (step.isBlank() && type.isBlank() && input.isBlank()) {
                    continue;
                }

                records.add(RecordFactory.createExcelTestStepRecord(TestStep.step(step), type.toUpperCase(), input));
            }
        }

        return records;
    }
    private static String getCellValue(Cell cell) {
        if (cell == null) return "";
        return switch (cell.getCellType()) {
            case STRING -> cell.getStringCellValue();
            case NUMERIC -> DateUtil.isCellDateFormatted(cell) ?
                    cell.getLocalDateTimeCellValue().toLocalDate().toString() :
                    String.valueOf(cell.getNumericCellValue());
            case BOOLEAN -> String.valueOf(cell.getBooleanCellValue());
            case FORMULA -> cell.getCellFormula();
            default -> "";
        };
    }
}

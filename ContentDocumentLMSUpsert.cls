global class ContentDocumentLMSUpsert implements Database.Batchable < Sobject > , Database.AllowsCallouts, Database.stateful {
    
    global List<ContentVersion> contentVersionForPage = new List<ContentVersion>();
    public static final Org_Wide_Setting__mdt orgWideSetting = NextCallQueryHandler.ORG_WIDE_SETTING;
    public static final List<String> sendTo = new List<String>(orgWideSetting.Admin_Users_Emails__c.split(','));
    global integer maxRetryLimit = getMaxRetryLimit();
    
    global Database.QueryLocator start(Database.BatchableContext batchableContext) {
        return Database.getQueryLocator([
            SELECT Id, ContentSize FROM ContentVersion
            where AppCode__c  = 'PT'
            and Entity_Id__c <> NULL
            and Template_Type__r.LMS_Code__c <> 330
            and isSentToLMS__c = FALSE
            and isSentToExtSystem__c = FALSE
            and isMajorVersion = FALSE
            and (LMS_Sync_Retry_Count__c = null OR LMS_Sync_Retry_Count__c < :maxRetryLimit)
            and (ExtSystem_Sync_Retry_Count__c = null OR ExtSystem_Sync_Retry_Count__c < :maxRetryLimit)
        ]);
    }
    
    global void execute(Database.BatchableContext batchableContext, List < ContentVersion > instances) {
        
        //system.debug('**instances.size() '+ instances.size());
        if (instances.size() == 0) {
            return;
        }
        if (instances.size() > 1) {
            throw new AsyncException('Batch size must be set to 1');
        }
        
        if(instances[0].ContentSize > = 5100000){
           instances[0].LMS_Sync_Retry_Count__c = maxRetryLimit;
           Database.update(instances[0],false);
        }
        
        if(instances[0].ContentSize <  5100000){        	 
          execute(instances[0].Id);
        }
    }
    
    global void execute(Id instanceId) {
        
        // Reselect
        ContentVersion record = selectDocuments(instanceId);
        
        // Nothing to do?
        if (record == NULL) {
            return;
        }
        
        system.debug('Opportunity Id: '+ record.Entity_Id__c);        
         // Reselect
        OpportunityLineItem OppoLineItem = selectLMSId(record.Entity_Id__c);
                
        // Nothing to do?
        if (OppoLineItem == NULL) {
            return;
        }
        
        system.debug('LMS Job Number: '+ OppoLineItem.LMS_Job_Number__c);
        system.debug('Disposition: ' + OppoLineItem.Opportunity.Disposition__c);
        
        if(string.isBlank(OppoLineItem.LMS_Job_Number__c) && (OppoLineItem.Opportunity.Disposition__c == OpportunityConstant.DISPOSITION_PRESENTATION_CREDIT_REJECT)) {
        	record.isSentToLMS__c = TRUE;
        	update record;
        	return;        
        }
        
        //system.debug('found id'+ OppoLineItem);        
        
        system.debug('Opportunity Branch: ' + OppoLineItem.Opportunity.Branch__c);
        List<Branch_App_Feature__c> branchAppFeature = [Select Id, Feature__c from Branch_App_Feature__c Where Business_Unit__c = :OppoLineItem.Opportunity.Branch__c Limit 1];
                      
        //check EPA feature is enabled for branch assiged to consultation and document type is Pre Renovation form.
        if((branchAppFeature != null) && (branchAppFeature.size() > 0) && (branchAppFeature[0].Feature__c.contains(SyncLogConstant.EPA_FEATURE)) && (record.Template_Type__r.Lms_code__c == SyncLogConstant.PRE_RENOVATION_FORM_LMS_CODE)) {      		
        		system.debug('Branch App Feature: ' + branchAppFeature[0]);
        		system.debug('Branch Feature: ' + branchAppFeature[0].Feature__c);
        		system.debug('Template LMS Code: ' + record.Template_Type__r.Lms_code__c);         
        		ContentDocumentEPAUpsert.execute(record);        		        	
        }
        else {
	        // Crate sync
	        Sync_Log__c sync = new Sync_Log__c();
	        sync.Opportunity__c = record.Entity_Id__c;
	        sync.LMS_Request_Type__c = SyncLogConstant.LMS_REQUEST_TYPE_DOCUMENT;
	        // Create callout
	        SyncLogCallout syncLogCallout = new SyncLogCallout(sync);
	        
	        try {
	            // Run it
	            syncLogCallout.generateSyncForLMSDocUpload(getJson(record,OppoLineItem.LMS_Job_Number__c));
	            syncLogCallout.executeCallout();
	            
	            // Handle response
	            syncLogCallout.processResponseAsLMSDocUpload();
	            
	            // Success?
	            if (syncLogCallout.isSuccess()) {
	                record.LMS_Doc_Id__c = sync.External_ID_1__c;
	                //record.IsMajorVersion = false;
	                record.isSentToLMS__c = TRUE;
	            }
	            else {
	                record.isSentToLMS__c = FALSE;
	                
	                if (record.LMS_Sync_Retry_Count__c == null){
	                    record.LMS_Sync_Retry_Count__c = 1;
	                }else {
	                    record.LMS_Sync_Retry_Count__c = record.LMS_Sync_Retry_Count__c + 1;
	                }
	                
	                if (record.LMS_Sync_Retry_Count__c == maxRetryLimit) {
	                    contentVersionForPage.add(record);
	                }
	            }           
	            // Save record
	            Database.update(record,false);
	            
	        } catch (Exception problem) {
	            syncLogCallout.setError(problem);
	        }
	        // Save sync log.
	        syncLogCallout.commitSync();
        }
    }
    
    global void finish(Database.BatchableContext batchableContext) {
        EmailServiceForBatch.invoke(batchableContext.getJobId(), 'ContentDocumentLMSUpsert');
        if (!contentVersionForPage.isEmpty()) {
            sendEmailToAdmins(contentVersionForPage);
        }
        schedule();
    }
    
    global static void schedule() {
        if (DateTime.now().hour() < MaintenanceRestarts.RESTART_HOUR) {
            return; // jobs don't run between midnight (hour 0) and RESTART_HOUR (usually hour 2 or 4)
        }
        
        if (Test.isRunningTest()) {
            return; // jobs don't run during tests
        }
        
        // Delay?
        Integer delay = LmsConstant.SYNC_DELAY_NORMAL;
        
        // Schedule
        System.scheduleBatch(new ContentDocumentLMSUpsert(), 'ContentDocumentLMSUpsert', delay, 1);
    }
    
    private void sendEmailToAdmins(List<ContentVersion> records){
        if (records == null || records.size() == 0) {
            return;
        }
        
        String recordIds = '';
        
        for (ContentVersion record : records) {
            if (recordIds == '')
            recordIds = record.Id;
            else
            recordIds = recordIds + ' , ' + record.Id;
        }
        
        // Send an email to Admin Users 
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(sendTo);
        mail.setSubject('Content documents not processed in LMS');
        mail.setPlainTextBody('Following content documents not processed in LMS: '+recordIds);
        //mail.emailPriority = 'Highest';
        Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
    }
    
    public OpportunityLineItem selectLMSId(string opportunityId ) {
        OpportunityLineItem[] records = [
            SELECT LMS_Job_Number__c
            , Opportunity.Branch__c
            , Opportunity.Disposition__c
            FROM OpportunityLineItem
            WHERE opportunityId = :opportunityId 
            AND LMS_Job_Number__c <> NULL
            LIMIT 1
        ];        
        
        // Validate record still meets entry criteria
        return records.isEmpty() ? NULL : records[0];
    }
    
    public ContentVersion selectDocuments(Id recordId ) {
        ContentVersion[] records = [
            SELECT Document_Type__c, Id, Entity_Id__c,Template_Type__r.Lms_code__c,
            LMS_User_Number__c,FileType ,Title ,VersionData,LMS_Doc_Id__c, LMS_Sync_Retry_Count__c
            FROM ContentVersion
            WHERE Id = : recordId
            
            LIMIT 1
            FOR UPDATE
        ];
        
        // Validate record still meets entry criteria
        return records.isEmpty() ? NULL : records[0];
    }
    
    //
    // Generate the JSON body data
    //
    
    public String getJson(ContentVersion record , string LmsId) {
        if (record == NULL) {
            return null;
        }
        if (String.isEmpty(LmsId)) {
            return null;
        }
        Map < String, String > req = new Map < String, String > ();
        
        req.put('leadId', LmsId); // entity_id__c
        req.put('entityUser', record.LMS_User_Number__c); // lmsuserno
        req.put('classification', 'Sales'); //sales
        req.put('businessDocTypCode', string.valueOf(record.Template_type__r.LMS_code__c)); //contentversion.template_type__r.lms_code__c
        req.put('docType', record.FileType); // filetype
        req.put('docName', record.Title); //title
        req.put('docContent', EncodingUtil.base64Encode(record.VersionData)); //versiondata
        
        // Done
        return Json.serialize(req);
    }
    
    private integer getMaxRetryLimit(){
        MetadataSettings.LMS_REQUEST_TYPE = SyncLogConstant.LMS_REQUEST_TYPE_DOCUMENT;
        return Integer.valueOf(MetadataSettings.LMS_SETTINGS.Retry_Attempts__c);
    }
    
    public class ContentDocResponse{
        public documentResponse documentResponse;
    }
    public class documentResponse {
        public document document;
        public header header;
    }
    public class document {
        public string docId;    //1549082
        public String docName;  //1-1JW73KC_Pricing_Worksheet
        public String docType;  //PDF
        public string docSize;  //0
        public string entityUser;   //15768
        public string leadId;   //9989890
        public String classification;   //Sales
        public string businessDocTypCode;   //220
    }
    public class header {
        public string status;   //200
        public string code; //200
        public String message;  //Success
    }
}
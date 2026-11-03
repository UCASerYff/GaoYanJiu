"""Targeted source-export safety; all files live in new private fixtures."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('funding_export', Path(__file__).parents[1] / 'scripts/export_research_funding.py')
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)

class FundingExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='research-funding-', suffix='.noindex', dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.record = {'id':'original-id','name':'Public synthetic research plan','amount':123.456789,
                       'year':2026,'months':[1,3,12],'receivingAccount':'Original free text; not an account ID',
                       'createdAt':'2025-01-01T01:02:03Z','updatedAt':'2026-10-01T01:02:03.123Z'}
        deleted = copy.deepcopy(self.record); deleted['id'] = 'deleted-funding-id'
        self.trash = {'id':'original-trash-id','kind':'funding','title':'Deleted funding','deletedAt':'2026-09-01T01:02:03Z',
                      'funding':deleted,'documents':[],'originalExtension':{'retain':'exact'}}
        self.library = {'version':32,'fundingRecords':[self.record],'trashItems':[self.trash,{'id':'other-trash','kind':'project'}],
                        'rewardCity':{'balance':987,'rewardedWorkIDs':['retain']},'projects':[{'id':'keep-project'}]}
        for collection in ['papers','portals','existingWorks','certificates','documentFolders','managedDocuments']:
            self.library[collection]=[]

    def tearDown(self):
        self.temp.cleanup()

    def raw(self, value=None):
        return json.dumps(self.library if value is None else value, ensure_ascii=False, allow_nan=False).encode()

    def project(self, value=None):
        raw = self.raw(value)
        return engine.projection(raw, engine.sha(raw), '2026-11-02T00:00:00Z')

    def test_complete_original_fields_trash_and_no_balances_or_rewards(self):
        value = self.project()
        self.assertEqual(value['fundingRecords'],[self.record]); self.assertEqual(value['trashItems'],[self.trash])
        self.assertEqual(value['attachments'],[]); self.assertEqual(value['relatedProjects'],[])
        self.assertNotIn('rewardCity',value); self.assertNotIn('ledger',value)
        self.assertEqual(value['sourceRevision'],engine.sha(self.raw()))

    def test_export_is_exclusive_complete_and_source_bytes_metadata_unchanged(self):
        source = self.root/'frozen-library.json'; source.write_bytes(self.raw())
        before = engine.signature(source.stat()); before_raw=source.read_bytes()
        output=self.root/'research-funding-v1.json'
        result=engine.export(source,engine.sha(before_raw),output)
        self.assertTrue(result['ok']); self.assertFalse(result['authoritySwitched'])
        self.assertEqual(output.stat().st_mode & 0o777,0o600)
        self.assertEqual(source.read_bytes(),before_raw); self.assertEqual(engine.signature(source.stat()),before)
        self.assertEqual(json.loads(output.read_bytes())['fundingRecords'],[self.record])
        before_out=output.read_bytes()
        with self.assertRaises(engine.ExportError):engine.export(source,engine.sha(before_raw),output)
        self.assertEqual(output.read_bytes(),before_out)
        self.assertEqual(list(self.root.glob('*.partial.noindex')),[])

    def test_revision_or_missing_source_fail_before_output(self):
        source=self.root/'source.json';source.write_bytes(self.raw());out=self.root/'research-funding-v1.json'
        with self.assertRaises(engine.ExportError):engine.export(source,'0'*64,out)
        self.assertFalse(out.exists())
        source.unlink()
        with self.assertRaises(FileNotFoundError):engine.export(source,'0'*64,out)
        self.assertFalse(out.exists())

    def test_symlink_input_or_output_parent_refused(self):
        source=self.root/'source.json';source.write_bytes(self.raw());link=self.root/'source-link.json';link.symlink_to(source)
        with self.assertRaises(engine.ExportError):engine.export(link,engine.sha(self.raw()),self.root/'research-funding-v1.json')
        real=self.root/'private';real.mkdir(mode=0o700);alias=self.root/'alias';alias.symlink_to(real)
        with self.assertRaises(engine.ExportError):engine.export(source,engine.sha(self.raw()),alias/'research-funding-v1.json')

    def test_missing_collections_and_future_schema_never_become_empty(self):
        for key in ['fundingRecords','trashItems','papers','rewardCity']:
            value=copy.deepcopy(self.library);del value[key]
            with self.assertRaises(engine.ExportError):self.project(value)
        for schema in [31,33,True]:
            value=copy.deepcopy(self.library);value['version']=schema
            with self.assertRaises(engine.ExportError):self.project(value)

    def test_invalid_or_unknown_record_fields_refused_without_coercion(self):
        for field,value in [('amount',-1),('amount',True),('year','2026'),('months',[1,1]),('months',[0,13]),('months',[True]),('createdAt','not-a-date')]:
            lib=copy.deepcopy(self.library);lib['fundingRecords'][0][field]=value
            with self.assertRaises(engine.ExportError):self.project(lib)
        lib=copy.deepcopy(self.library);lib['fundingRecords'][0]['attachments']=['unknown']
        with self.assertRaises(engine.ExportError):self.project(lib)

    def test_duplicate_ids_relationships_and_inconsistent_trash_refused(self):
        lib=copy.deepcopy(self.library);lib['fundingRecords'].append(copy.deepcopy(self.record))
        with self.assertRaises(engine.ExportError):self.project(lib)
        lib=copy.deepcopy(self.library);lib['trashItems'][0]['funding']['id']=self.record['id']
        with self.assertRaises(engine.ExportError):self.project(lib)
        for field,value in [('project',{'id':'unknown'}),('documents',[{'id':'unknown'}])]:
            lib=copy.deepcopy(self.library);lib['trashItems'][0][field]=value
            with self.assertRaises(engine.ExportError):self.project(lib)
        lib=copy.deepcopy(self.library);lib['trashItems'][0]['kind']='project'
        with self.assertRaises(engine.ExportError):self.project(lib)
        lib=copy.deepcopy(self.library);lib['trashItems'][1]['id']=lib['trashItems'][0]['id']
        with self.assertRaises(engine.ExportError):self.project(lib)

    def test_duplicate_keys_and_nonfinite_json_refused(self):
        for raw in [b'{"version":32,"version":32,"fundingRecords":[],"trashItems":[]}',
                    b'{"version":32,"fundingRecords":[],"trashItems":[],"bad":NaN}']:
            with self.assertRaises(engine.ExportError):engine.projection(raw,engine.sha(raw))

if __name__=='__main__':
    unittest.main()

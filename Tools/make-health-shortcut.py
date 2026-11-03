#!/usr/bin/env python3
"""Builds "Blood Pressure to Health.shortcut", the iPhone side of the Apple
Health hand-off (see App/BPTracker/Model/HealthExporter.swift).

The shortcut reads every file in iCloud Drive › Shortcuts › Blood Pressure,
logs each line (date,systolic,diastolic,pulse) to Health unless Health already
has a systolic sample in that minute, then deletes the file. The heart rate is
logged only with a new blood-pressure reading and only when the pulse is above 0.

Usage: Tools/make-health-shortcut.py  (writes and signs the file in App/BPTracker/Resources)
       Tools/make-health-shortcut.py --unsigned out.plist  (plain plist, for comparing)

Apple does not document the format. Parameter encodings here match what the
Shortcuts app itself stores after setting the fields by hand on an iPhone
(checked on 2026-11-02 against a shortcut exported with Share › Save to Files and
unpacked: the file is an AEA1 archive signed by the key in its auth data's
SigningCertificateChain; `aea decrypt -sign-pub` then `aa extract` give the plist).
The action and parameter names appear in the system's Shortcuts frameworks.
"""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

FOLDER = "Blood Pressure/"  # relative to iCloud Drive › Shortcuts
OUT = os.path.join(os.path.dirname(__file__), "..", "App", "BPTracker", "Resources", "Blood Pressure to Health.shortcut")


def new_id():
    return str(uuid.uuid4()).upper()


def output(uid, name):
    return {"OutputUUID": uid, "Type": "ActionOutput", "OutputName": name}


def attachment(uid, name):
    """A parameter that is exactly one action's output."""
    return {"Value": output(uid, name), "WFSerializationType": "WFTextTokenAttachment"}


def token_string(uid, name):
    """A text parameter consisting of one action's output."""
    return {"Value": {"string": "\ufffc", "attachmentsByRange": {"{0, 1}": output(uid, name)}},
            "WFSerializationType": "WFTextTokenString"}


def quantity(uid, name, unit):
    """A number-with-unit field (Log Health Sample) taking its number from an action's output.

    The magnitude is the bare output reference. Wrapping it in a WFTextTokenAttachment
    imports as "Unknown Variable"."""
    return {"Value": {"Magnitude": output(uid, name), "Unit": unit}, "WFSerializationType": "WFQuantityFieldValue"}


def variable(name):
    return {"Value": {"Type": "Variable", "VariableName": name}, "WFSerializationType": "WFTextTokenAttachment"}


def action(identifier, **params):
    params.setdefault("UUID", new_id())  # Shortcuts gives every action one when saving
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": params}


actions = []
add = actions.append

get_folder = new_id()
add(action("is.workflow.actions.documentpicker.open", UUID=get_folder, WFShowFilePicker=False,
           WFGetFilePath=FOLDER, WFFileErrorIfNotFound=True))
contents = new_id()
add(action("is.workflow.actions.file.getfoldercontents", UUID=contents, WFFolder=attachment(get_folder, "File")))

files_loop = new_id()
add(action("is.workflow.actions.repeat.each", GroupingIdentifier=files_loop, WFControlFlowMode=0,
           WFInput=attachment(contents, "Folder Contents")))
text = new_id()
add(action("is.workflow.actions.detect.text", UUID=text, WFInput=variable("Repeat Item")))
lines = new_id()
add(action("is.workflow.actions.text.split", UUID=lines, text=attachment(text, "Text"), WFTextSeparator="New Lines"))

lines_loop = new_id()
add(action("is.workflow.actions.repeat.each", GroupingIdentifier=lines_loop, WFControlFlowMode=0,
           WFInput=attachment(lines, "Split Text")))
fields = new_id()
add(action("is.workflow.actions.text.split", UUID=fields, text=variable("Repeat Item 2"), WFTextSeparator="Custom", WFTextCustomSeparator=","))

items = {}
for index, name in [(1, "Date Text"), (2, "Systolic"), (3, "Diastolic"), (4, "Pulse")]:
    uid = new_id()
    items[name] = uid
    add(action("is.workflow.actions.getitemfromlist", UUID=uid, CustomOutputName=name,
               WFInput=attachment(fields, "Split Text"), WFItemSpecifier="Item At Index", WFItemIndex=index))

date = new_id()
add(action("is.workflow.actions.detect.date", UUID=date, CustomOutputName="Reading Date",
           WFInput=attachment(items["Date Text"], "Date Text")))
minute_later = new_id()
add(action("is.workflow.actions.adjustdate", UUID=minute_later, CustomOutputName="Minute Later",
           WFDate=token_string(date, "Reading Date"), WFAdjustOperation="Add",
           WFDuration={"Value": {"Unit": "min", "Magnitude": "1"}, "WFSerializationType": "WFQuantityFieldValue"}))
half_minute_before = new_id()
add(action("is.workflow.actions.adjustdate", UUID=half_minute_before,
           WFDate=token_string(date, "Reading Date"), WFAdjustOperation="Subtract",
           WFDuration={"Value": {"Unit": "sec", "Magnitude": "30"}, "WFSerializationType": "WFQuantityFieldValue"}))

# Duplicate check: Health samples around this minute, their start times as
# "yyyy-MM-dd HH:mm" text, and log only if this line's date text is not among them.
existing = new_id()
add(action("is.workflow.actions.filter.health.quantity", UUID=existing, CustomOutputName="Existing Samples",
           WFContentItemFilter={
               "Value": {
                   "WFActionParameterFilterPrefix": 1,
                   "WFContentPredicateBoundedDate": False,
                   "WFActionParameterFilterTemplates": [
                       {"Operator": 4, "Property": "Type", "Removable": False, "Bounded": True,
                        "Values": {"Enumeration": {"Value": "Systolic Blood Pressure",
                                                   "WFSerializationType": "WFStringSubstitutableState"}}},
                       {"Operator": 4, "Property": "Start Date", "Removable": False, "Bounded": True,
                        "Values": {"Date": attachment(half_minute_before, "Adjusted Date"),
                                   "AnotherDate": attachment(minute_later, "Minute Later"),
                                   "Unit": 16, "Number": "7"}},
                   ],
               },
               "WFSerializationType": "WFContentPredicateTableTemplate",
           },
           WFContentItemLimitEnabled=False, WFContentItemLimitNumber=1.0))
start_dates = new_id()
add(action("is.workflow.actions.properties.health.quantity", UUID=start_dates,
           WFInput=attachment(existing, "Existing Samples"), WFContentItemPropertyName="Start Date"))
formatted = new_id()
add(action("is.workflow.actions.format.date", UUID=formatted, WFDateFormatStyle="Custom", WFDateFormat="yyyy-MM-dd HH:mm",
           WFDate=token_string(start_dates, "Start Date")))
combined = new_id()
add(action("is.workflow.actions.text.combine", UUID=combined, text=attachment(formatted, "Formatted Date")))

not_in_health = new_id()
add(action("is.workflow.actions.conditional", GroupingIdentifier=not_in_health, WFControlFlowMode=0,
           WFCondition=999,  # does not contain
           WFInput={"Type": "Variable", "Variable": attachment(combined, "Combined Text")},
           WFConditionalActionString=token_string(items["Date Text"], "Date Text"), WFNumberValue="0"))
# Blood pressure is stored as type "Systolic Blood Pressure" with the diastolic value
# as the additional quantity; magnitudes are bare output references.
add(action("is.workflow.actions.health.quantity.log", WFQuantitySampleType="Systolic Blood Pressure",
           WFQuantitySampleQuantity=quantity(items["Systolic"], "Systolic", "mmHg"),
           WFQuantitySampleAdditionalQuantity=quantity(items["Diastolic"], "Diastolic", "mmHg"),
           WFQuantitySampleDate=token_string(date, "Reading Date")))
pulse_number = new_id()
add(action("is.workflow.actions.detect.number", UUID=pulse_number, WFInput=attachment(items["Pulse"], "Pulse")))
has_pulse = new_id()
add(action("is.workflow.actions.conditional", GroupingIdentifier=has_pulse, WFControlFlowMode=0,
           WFCondition=2,  # is greater than
           WFNumberValue="0", WFInput={"Type": "Variable", "Variable": attachment(pulse_number, "Numbers")}))
add(action("is.workflow.actions.health.quantity.log", WFQuantitySampleType="Heart Rate",
           WFQuantitySampleQuantity=quantity(pulse_number, "Numbers", "count/min"),
           WFQuantitySampleDate=token_string(date, "Reading Date")))
add(action("is.workflow.actions.conditional", GroupingIdentifier=has_pulse, WFControlFlowMode=1))
add(action("is.workflow.actions.conditional", GroupingIdentifier=has_pulse, WFControlFlowMode=2))
add(action("is.workflow.actions.conditional", GroupingIdentifier=not_in_health, WFControlFlowMode=1))
add(action("is.workflow.actions.conditional", GroupingIdentifier=not_in_health, WFControlFlowMode=2))

add(action("is.workflow.actions.repeat.each", GroupingIdentifier=lines_loop, WFControlFlowMode=2))
add(action("is.workflow.actions.file.delete", WFInput=variable("Repeat Item"), WFDeleteFileConfirmDeletion=False))
add(action("is.workflow.actions.repeat.each", GroupingIdentifier=files_loop, WFControlFlowMode=2))

workflow = {
    "WFWorkflowClientVersion": "2302.0.4",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowTypes": [],
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowHasOutputFallback": False,
    "WFWorkflowImportQuestions": [],
    "WFQuickActionSurfaces": [],
    "WFWorkflowActions": actions,
}

if len(sys.argv) == 3 and sys.argv[1] == "--unsigned":
    # For inspection: write the plain plist without signing.
    with open(sys.argv[2], "wb") as f:
        plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
    sys.exit(0)

with tempfile.TemporaryDirectory() as tmp:
    unsigned = os.path.join(tmp, "unsigned.shortcut")
    with open(unsigned, "wb") as f:
        plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
    # The signing service may not be allowed to write to the project's volume, so sign into the temp folder.
    signed = os.path.join(tmp, "signed.shortcut")
    result = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", signed],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"shortcuts sign failed: {result.stderr or result.stdout}")
    out = os.path.abspath(OUT)
    shutil.copyfile(signed, out)
print(f"wrote {out} ({len(actions)} actions)")

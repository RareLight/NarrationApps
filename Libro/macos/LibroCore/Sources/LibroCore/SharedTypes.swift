import NarrationCore
import Pronunciation
import DocumentProcessing
import NativeSpeech
import AudioOutput
import ProcessingPipeline

// Compatibility names at the app boundary; implementations live in swift-packages.
public typealias DocumentReadError = NarrationCore.DocumentReadError
public typealias ModelPreparationProgress = NarrationCore.ModelPreparationProgress
public typealias DocumentPreparationProgress = NarrationCore.DocumentPreparationProgress
public typealias TextPreparationProgress = ProcessingPipeline.TextPreparationProgress
public typealias NarrationText = NarrationCore.NarrationText
public typealias PlanningError = NarrationCore.PlanningError
public typealias OutputPaths = NarrationCore.OutputPaths
public typealias ContentBlock = NarrationCore.ContentBlock
public typealias SemanticDocument = NarrationCore.SemanticDocument
public typealias NarrationChunk = NarrationCore.NarrationChunk
public typealias NarrationPlan = NarrationCore.NarrationPlan
public typealias SpeechFailureCode = NarrationCore.SpeechFailureCode
public typealias SpeechFailure = NarrationCore.SpeechFailure
public typealias AttemptIdentity = NarrationCore.AttemptIdentity
public typealias WorkerCommand = NarrationCore.WorkerCommand
public typealias WorkerEvent = NarrationCore.WorkerEvent
public typealias SpeechIPC = NarrationCore.SpeechIPC
public typealias WorkerCommandReader = NarrationCore.WorkerCommandReader
public typealias SpeechModel = NarrationCore.SpeechModel
public typealias SpeechCapabilities = NarrationCore.SpeechCapabilities
public typealias SpeechSettings = NarrationCore.SpeechSettings
public typealias SpeechSetupOnboarding = NarrationCore.SpeechSetupOnboarding
public typealias VoiceSamples = NativeSpeech.VoiceSamples
public typealias AudioPreviewPlayer = AudioOutput.AudioPreviewPlayer
public typealias DocumentReader = DocumentProcessing.DocumentReader
public typealias DocumentKind = DocumentProcessing.DocumentKind
public typealias TextFileEncoding = DocumentProcessing.TextFileEncoding
public typealias InputDocument = DocumentProcessing.InputDocument
public typealias IntakeIssue = DocumentProcessing.IntakeIssue
public typealias IntakeResult = DocumentProcessing.IntakeResult
public typealias InputCollector = DocumentProcessing.InputCollector
public typealias NativeAcquisitionFile = NativeSpeech.NativeAcquisitionFile
public typealias NativeAcquisitionProgress = NativeSpeech.NativeAcquisitionProgress
public typealias NativeAssetError = NativeSpeech.NativeAssetError
public typealias NativeWorkspace = NativeSpeech.NativeWorkspace
public typealias NativeG2P = NativeSpeech.NativeG2P
public typealias NativePrimaryCatalog = NativeSpeech.NativePrimaryCatalog
public typealias NativePrimaryFile = NativeSpeech.NativePrimaryFile
public typealias NativePrimarySpecification = NativeSpeech.NativePrimarySpecification
public typealias NativePrimaryStore = NativeSpeech.NativePrimaryStore
public typealias NativePrimaryRecord = NativeSpeech.NativePrimaryRecord
public typealias SpeechMemoryPolicy = NativeSpeech.SpeechMemoryPolicy
public typealias AudioOutputError = AudioOutput.AudioOutputError
public typealias AtomicAudioWriter = AudioOutput.AtomicAudioWriter
public typealias AudioOutputFormat = AudioOutput.AudioOutputFormat
public typealias PlannedDocument = ProcessingPipeline.PlannedDocument
public typealias BatchRequest = ProcessingPipeline.BatchRequest
public typealias BatchPlanner = ProcessingPipeline.BatchPlanner
public typealias SpeechProgress = ProcessingPipeline.SpeechProgress
public typealias ChunkScheduler = ProcessingPipeline.ChunkScheduler
public typealias DebugLog = ProcessingPipeline.DebugLog
public typealias ModelPreparation = ProcessingPipeline.ModelPreparation
public typealias DocumentOutcome = ProcessingPipeline.DocumentOutcome
public typealias BatchSummary = ProcessingPipeline.BatchSummary
public typealias BatchEvent = ProcessingPipeline.BatchEvent
public typealias CoordinatorError = ProcessingPipeline.CoordinatorError
public typealias QueueCoordinator = ProcessingPipeline.QueueCoordinator
public typealias WorkerConfiguration = ProcessingPipeline.WorkerConfiguration

public typealias PronunciationStore = Pronunciation.PronunciationStore

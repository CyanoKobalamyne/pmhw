////////////////////////////////////////////////////////////////////////////////
//  Filename      : Scheduler.bsv
//  Description   : Computes a vector of compatible transactions from among the
//                  ones in the input vector based on their read and write sets.
////////////////////////////////////////////////////////////////////////////////
import ClientServer::*;
import GetPut::*;
import Vector::*;

////////////////////////////////////////////////////////////////////////////////
/// Module interface.
////////////////////////////////////////////////////////////////////////////////
typedef 10 LogNumberLiveObjects;
typedef 3 LogSizeSchedulingPool;
typedef 1 LogNumberComparators;

typedef TAdd#(1, LogNumberLiveObjects) ObjectCount;
typedef TMul#(2, NumberComparators) SizeComparisonPool;
typedef TDiv#(SizeSchedulingPool, NumberComparators) NumberComparisonChunks;

typedef TExp#(LogNumberLiveObjects) NumberLiveObjects;
typedef TExp#(LogSizeSchedulingPool) SizeSchedulingPool;
typedef TExp#(LogNumberComparators) NumberComparators;

typedef Bit#(LogNumberLiveObjects) ObjectName;
typedef Bit#(LogSizeSchedulingPool) SchedulingPoolIndex;
typedef Bit#(ObjectCount) ReferenceCounter;
typedef Bit#(NumberLiveObjects) ObjectSet;
typedef Bit#(SizeSchedulingPool) ContainedTransactions;

typedef Vector#(SizeSchedulingPool, TransactionSet) SchedulingPool;
typedef Vector#(SizeComparisonPool, TransactionSet) ComparisonPool;
typedef Vector#(NumberComparators, TransactionSet) MergedComparisonPool;

// A transaction set is composed of read set, a write set, and the bit vector
// indices. The indices are specific to a given round and indicate which
// transactions are in the set.
typedef struct {
    ObjectSet readSet;
    ObjectSet writeSet;
    ContainedTransactions indices;
} TransactionSet deriving(Bits, Eq, FShow);

typedef SchedulingPool SchedulingRequest;
typedef TransactionSet SchedulingResponse;
typedef Server#(SchedulingRequest, SchedulingResponse) Scheduler;

////////////////////////////////////////////////////////////////////////////////
/// Numeric constants.
////////////////////////////////////////////////////////////////////////////////
Integer logMaxLiveObjects = valueOf(LogNumberLiveObjects);
Integer maxLiveObjects = valueOf(NumberLiveObjects);
Integer logNumComparators = valueOf(LogNumberComparators);
Integer numComparators = valueOf(NumberComparators);
Integer maxRounds = valueOf(LogSizeSchedulingPool);
Integer maxScheduledObjects = valueOf(SizeSchedulingPool);

////////////////////////////////////////////////////////////////////////////////
/// Helper functions.
////////////////////////////////////////////////////////////////////////////////
// Merges two transactions sets, returning their union if they don't conflict,
// and returning the first set if they do.
function TransactionSet mergeTransactionSets(TransactionSet ts1, TransactionSet ts2);
    let r1w2_set = ts1.readSet & ts2.writeSet;
    let w1r2_set = ts1.writeSet & ts2.readSet;
    let w1w2_set = ts1.writeSet & ts2.writeSet;
    let conflicts = r1w2_set | w1r2_set | w1w2_set;
    let has_conflicts = conflicts != 0;
    if (has_conflicts) begin
        return ts1;
    end else begin
        return TransactionSet{
            readSet: ts1.readSet | ts2.readSet,
            writeSet: ts1.writeSet | ts2.writeSet,
            indices: ts1.indices | ts2.indices
        };
    end
endfunction

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
///
/// Tournament scheduler implementation.
///
/// We start with a vector of transaction sets, and merge them into half as many
/// transactions, each of which is either a combination of two transactions, if
/// those don't conflict, or only one of the two, if they do conlict.
///
/// Two transactions conflict if one of the reads an object that the other one
/// writes or if both of them write the same object. If two transactions
/// conflict, the first one (according to the order in the vector) progresses to
/// the next round.
///
/// Since the number of comparators might not be large enough to
/// allow comparing all pairs of transactions in the pool, some rounds can take
/// multiple cycles.
///
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
module mkScheduler(Scheduler);
    ////////////////////////////////////////////////////////////////////////////////
    /// Design elements.
    ////////////////////////////////////////////////////////////////////////////////
    // Transaction sets. The number of "active" transaction sets is halved in
    // each round. These are stored in this vector contiguously, flushed to the
    // left (starting at index 0).
    Reg#(Maybe#(SchedulingPool)) trSets <- mkReg(tagged Invalid);
    // Tournament round.
    Reg#(SchedulingPoolIndex) round <- mkReg(0);
    // Number of transactions that have already been merged in this round.
    Reg#(SchedulingPoolIndex) offset <- mkReg(0);

    ////////////////////////////////////////////////////////////////////////////////
    /// Rules.
    ////////////////////////////////////////////////////////////////////////////////
    rule doTournament if (isValid(trSets) && round < fromInteger(maxRounds));
        SchedulingPool currentTrSets = fromMaybe(?, trSets);
        // Extract transactions to be merged, starting at offset. rotateBy rotates
        // to the right, so we compute the offset from the other end of the vector.
        SchedulingPoolIndex revOffset = fromInteger(maxScheduledObjects - 1) - offset + 1;
        SchedulingPool rotatedTrSets = rotateBy(currentTrSets, unpack(revOffset));
        ComparisonPool activeTrSets = take(rotatedTrSets);
        // Merge transactions pairwise.
        MergedComparisonPool mergedTrSets = mapPairs(mergeTransactionSets, id, activeTrSets);
        // Split original vector into chunks and replace chunk corresponding
        // to these transactions in the next round.
        Vector#(NumberComparisonChunks, MergedComparisonPool) chunks = toChunks(currentTrSets);
        SchedulingPoolIndex chunkIndex = (offset >> 1) >> logNumComparators;
        chunks[chunkIndex] = mergedTrSets;
        // Concatenate chunks and update state.
        SchedulingPool newTrSets = concat(chunks);
        trSets <= tagged Valid newTrSets;
        // Compute next offset and round.
        // newOffset = (offset + 2*numComparators) % (SizeSchedulingPool / 2^round)
        SchedulingPoolIndex numMergedTr = fromInteger((numComparators * 2) % maxScheduledObjects);
        SchedulingPoolIndex mask = (1 << (fromInteger(maxRounds) - round)) - 1;
        SchedulingPoolIndex newOffset = (offset + numMergedTr) & mask;
        offset <= newOffset;
        if (newOffset == 0) begin
            round <= round + 1;
        end
    endrule

    ////////////////////////////////////////////////////////////////////////////////
    /// Interface connections and methods.
    ////////////////////////////////////////////////////////////////////////////////
    interface Put request;
        method Action put(SchedulingRequest inputTransactions) if (!isValid(trSets));
            trSets <= tagged Valid inputTransactions;
            round <= 0;
            offset <= 0;
        endmethod
    endinterface

    interface Get response;
        method ActionValue#(SchedulingResponse) get() if (isValid(trSets) && round == fromInteger(maxRounds));
            trSets <= tagged Invalid;
            return fromMaybe(?, trSets)[0];
        endmethod
    endinterface
endmodule

////////////////////////////////////////////////////////////////////////////////
// Scheduler tests.
////////////////////////////////////////////////////////////////////////////////
typedef 8 NumberSchedulerTests;

module mkSchedulerTestbench();
    Scheduler myScheduler <- mkScheduler();

    Vector#(NumberSchedulerTests, SchedulingRequest) testInputs = newVector;
    // Empty transactions.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[0][i] = TransactionSet{
            readSet: 'b0,
            writeSet: 'b0,
            indices: 'b1 << i
        };
    end
    // Non-conflicting read-only transactions.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[1][i] = TransactionSet{
            readSet: 'b1 << i,
            writeSet: 'b0,
            indices: 'b1 << i
        };
    end
    // Overlapping read-only transactions.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[2][i] = TransactionSet{
            readSet: 'b1111 << i,
            writeSet: 'b0,
            indices: 'b1 << i
        };
    end
    // Non-conflicting read-write transactions.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[3][i] = TransactionSet{
            readSet: 'b11 << (2 * i),
            writeSet: 'b1 << (maxLiveObjects - i - 1),
            indices: 'b1 << i
        };
    end
    // Non-conflicting read-write transactions with overlapping reads.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[4][i] = TransactionSet{
            readSet: 'b1111 << i,
            writeSet: 'b1 << (maxLiveObjects - i - 1),
            indices: 'b1 << i
        };
    end
    // Transactions with read-write conflicts.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[5][i] = TransactionSet{
            readSet: 'b11 << (2 * i),
            writeSet: 'b100 << (2 * i),
            indices: 'b1 << i
        };
    end
    // Transacions with write-write conflicts.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[6][i] = TransactionSet{
            readSet: 'b1000 << i,
            writeSet: 'b1 << (i % 3),
            indices: 'b1 << i
        };
    end
    // Transactions with both conflicts.
    for (Integer i=0; i < maxScheduledObjects; i = i + 1) begin
        testInputs[7][i] = TransactionSet{
            readSet: 'b1010 << i,
            writeSet: 'b101 << i,
            indices: 'b1 << i
        };
    end

    Reg#(UInt#(32)) counter <- mkReg(0);

    rule feed if (counter < fromInteger(valueOf(NumberSchedulerTests)));
        counter <= counter + 1;
        myScheduler.request.put(testInputs[counter]);
    endrule

    rule stream;
        let result <- myScheduler.response.get();
        $display(fshow(result));
    endrule
endmodule
